import Foundation
import CryptoKit
import Compression

/// App Group storage for Call Directory snapshots and managed contacts registry.
final class SecureNodeAppGroupStore {
    private let appGroupId: String
    private let fm = FileManager.default

    init(appGroupId: String) {
        self.appGroupId = appGroupId
    }

    private func containerURL() throws -> URL {
        if let url = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            return url
        }
        throw SecureNodeError.invalidAppGroup
    }

    private func ensureDirs(base: URL) throws {
        let snapshots = base.appendingPathComponent("snapshots", isDirectory: true)
        if !fm.fileExists(atPath: snapshots.path) {
            try fm.createDirectory(at: snapshots, withIntermediateDirectories: true)
        }
    }

    func readCurrentPointer() throws -> SecureNodeCurrentPointer? {
        let base = try containerURL()
        let pointerURL = base.appendingPathComponent("current.json")
        guard fm.fileExists(atPath: pointerURL.path) else { return nil }
        let data = try Data(contentsOf: pointerURL)
        return try JSONDecoder().decode(SecureNodeCurrentPointer.self, from: data)
    }

    func writeSnapshot(entries: [SecureNodeSnapshotEntry], sinceCursor: String?) throws -> SecureNodeCurrentPointer {
        let base = try containerURL()
        try ensureDirs(base: base)

        let prev = try readCurrentPointer()
        let nextVersion = (prev?.version ?? 0) + 1

        let snapshotRel = "snapshots/snapshot_v\(nextVersion).json.gz"
        let validatorRel = "snapshots/snapshot_v\(nextVersion).validator.json"

        let snapshotURL = base.appendingPathComponent(snapshotRel)
        let validatorURL = base.appendingPathComponent(validatorRel)

        let payload = SecureNodeSnapshotPayload(schemaVersion: 1, createdAt: isoNow(), entries: entries)
        let rawJson = try JSONEncoder().encode(payload)
        let compressed = try ZlibGzipLike.compress(rawJson)

        let sha = Self.sha256Hex(compressed)
        let validator = SecureNodeSnapshotValidator(
            schemaVersion: 1,
            version: nextVersion,
            sha256: sha,
            count: entries.count,
            createdAt: isoNow()
        )
        let validatorJson = try JSONEncoder().encode(validator)

        // Two-phase commit
        let tmpSnapshot = snapshotURL.appendingPathExtension("tmp")
        let tmpValidator = validatorURL.appendingPathExtension("tmp")

        try compressed.write(to: tmpSnapshot, options: [.atomic])
        try validatorJson.write(to: tmpValidator, options: [.atomic])

        // Validate we can read/parse what we wrote.
        _ = try Self.readAndValidateSnapshot(at: tmpSnapshot, validatorData: validatorJson)

        // Move into place
        if fm.fileExists(atPath: snapshotURL.path) { try fm.removeItem(at: snapshotURL) }
        if fm.fileExists(atPath: validatorURL.path) { try fm.removeItem(at: validatorURL) }
        try fm.moveItem(at: tmpSnapshot, to: snapshotURL)
        try fm.moveItem(at: tmpValidator, to: validatorURL)

        // Update pointer last
        let pointer = SecureNodeCurrentPointer(
            version: nextVersion,
            snapshotPath: snapshotRel,
            validatorPath: validatorRel,
            sha256: sha,
            count: entries.count,
            createdAt: isoNow(),
            sinceCursor: sinceCursor
        )
        let pointerURL = base.appendingPathComponent("current.json")
        try JSONEncoder().encode(pointer).write(to: pointerURL, options: [.atomic])

        return pointer
    }

    static func readAndValidateSnapshot(at fileURL: URL, validatorData: Data) throws -> SecureNodeSnapshotPayload {
        let validator = try JSONDecoder().decode(SecureNodeSnapshotValidator.self, from: validatorData)
        let compressed = try Data(contentsOf: fileURL)
        let sha = sha256Hex(compressed)
        guard sha == validator.sha256 else { throw SecureNodeError.snapshotReadFailed }

        let raw = try ZlibGzipLike.decompress(compressed)
        let payload = try JSONDecoder().decode(SecureNodeSnapshotPayload.self, from: raw)
        guard payload.schemaVersion == validator.schemaVersion else { throw SecureNodeError.snapshotReadFailed }
        guard payload.entries.count == validator.count else { throw SecureNodeError.snapshotReadFailed }
        return payload
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

struct SecureNodeCurrentPointer: Codable {
    let version: Int
    let snapshotPath: String
    let validatorPath: String
    let sha256: String
    let count: Int
    let createdAt: String
    let sinceCursor: String?

    enum CodingKeys: String, CodingKey {
        case version
        case snapshotPath = "snapshot_path"
        case validatorPath = "validator_path"
        case sha256
        case count
        case createdAt = "created_at"
        case sinceCursor = "since_cursor"
    }
}

struct SecureNodeSnapshotPayload: Codable {
    let schemaVersion: Int
    let createdAt: String
    let entries: [SecureNodeSnapshotEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case createdAt = "created_at"
        case entries
    }
}

struct SecureNodeSnapshotValidator: Codable {
    let schemaVersion: Int
    let version: Int
    let sha256: String
    let count: Int
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case version
        case sha256
        case count
        case createdAt = "created_at"
    }
}

/// "gzip-like" compression using zlib container via Apple's Compression framework.
/// Stored with `.json.gz` extension for size reduction; the SDK/extension must use this codec.
enum ZlibGzipLike {
    static func compress(_ data: Data) throws -> Data {
        try perform(data: data, operation: COMPRESSION_STREAM_ENCODE)
    }

    static func decompress(_ data: Data) throws -> Data {
        try perform(data: data, operation: COMPRESSION_STREAM_DECODE)
    }

    private static func perform(data: Data, operation: compression_stream_operation) throws -> Data {
        var stream = compression_stream()
        var status = compression_stream_init(&stream, operation, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else { throw SecureNodeError.snapshotWriteFailed }
        defer { compression_stream_destroy(&stream) }

        let dstBufferSize = 64 * 1024
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstBufferSize)
        defer { dstBuffer.deallocate() }

        var output = Data()

        return try data.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Data in
            guard let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return Data() }
            stream.src_ptr = srcBase
            stream.src_size = data.count

            while true {
                stream.dst_ptr = dstBuffer
                stream.dst_size = dstBufferSize

                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = dstBufferSize - stream.dst_size
                    if produced > 0 { output.append(dstBuffer, count: produced) }
                    if status == COMPRESSION_STATUS_END { return output }
                default:
                    throw SecureNodeError.snapshotWriteFailed
                }
            }
        }
    }
}

