import Foundation

/// Helper for CNCallDirectoryExtension targets to read the latest validated snapshot.
public enum SecureNodeCallDirectorySnapshotReader {
    public static func loadEntries(appGroupId: String) throws -> [SecureNodeSnapshotEntry] {
        let fm = FileManager.default
        guard let base = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            throw SecureNodeError.invalidAppGroup
        }

        let pointerURL = base.appendingPathComponent("current.json")
        guard fm.fileExists(atPath: pointerURL.path) else { return [] }

        let pointerData = try Data(contentsOf: pointerURL)
        let pointer = try JSONDecoder().decode(SecureNodeCurrentPointer.self, from: pointerData)

        let snapshotURL = base.appendingPathComponent(pointer.snapshotPath)
        let validatorURL = base.appendingPathComponent(pointer.validatorPath)
        guard fm.fileExists(atPath: snapshotURL.path), fm.fileExists(atPath: validatorURL.path) else {
            return []
        }

        let validatorData = try Data(contentsOf: validatorURL)
        let payload = try SecureNodeAppGroupStore.readAndValidateSnapshot(at: snapshotURL, validatorData: validatorData)
        return payload.entries
    }
}

