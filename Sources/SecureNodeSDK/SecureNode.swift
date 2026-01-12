import Foundation
import CallKit
import Contacts

/// Headless, iOS-first SecureNode SDK facade.
///
/// - Owns: sync + caching + App Group snapshot + Call Directory reload policy + Contacts sync (managed contacts only)
/// - Does NOT own: any UI
public enum SecureNode {
    private static var core: SecureNodeCore?

    public static func configure(_ config: SecureNodeHeadlessConfig) {
        core = SecureNodeCore(config: config)
    }

    private static func requireCore() throws -> SecureNodeCore {
        if let c = core { return c }
        throw SecureNodeError.notConfigured
    }

    @discardableResult
    public static func sync() async throws -> SecureNodeSyncReport {
        let c = try requireCore()
        return try await c.sync()
    }

    @discardableResult
    public static func reloadCallDirectoryIfNeeded() async throws -> SecureNodeReloadReport {
        let c = try requireCore()
        return try await c.reloadCallDirectoryIfNeeded()
    }

    public static func health() throws -> SecureNodeHealthReport {
        let c = try requireCore()
        return c.health()
    }
}

public struct SecureNodeHeadlessConfig {
    public let apiURL: URL
    public let apiKey: String
    public let appGroupId: String
    public let callDirectoryExtensionBundleId: String
    public let directoryId: String?

    public let maxActiveNumbers: Int
    public let maxManagedContactProfiles: Int
    public let maxPhoneNumbersPerManagedContact: Int

    public init(
        apiURL: URL,
        apiKey: String,
        appGroupId: String,
        callDirectoryExtensionBundleId: String,
        directoryId: String? = nil,
        maxActiveNumbers: Int = 5_000,
        maxManagedContactProfiles: Int = 1_500,
        maxPhoneNumbersPerManagedContact: Int = 50
    ) {
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.appGroupId = appGroupId
        self.callDirectoryExtensionBundleId = callDirectoryExtensionBundleId
        self.directoryId = directoryId
        self.maxActiveNumbers = maxActiveNumbers
        self.maxManagedContactProfiles = maxManagedContactProfiles
        self.maxPhoneNumbersPerManagedContact = maxPhoneNumbersPerManagedContact
    }
}

public enum SecureNodeError: Error {
    case notConfigured
    case invalidAppGroup
    case snapshotWriteFailed
    case snapshotReadFailed
    case callDirectoryReloadFailed(String)
}

public struct SecureNodeSyncReport: Codable {
    public let syncedAt: String
    public let receivedCount: Int
    public let activeCount: Int
    public let snapshotVersion: Int
    public let contactsPermission: String
    public let managedContactsUpserted: Int
    public let managedContactsDeleted: Int
    public let photosApplied: Int
    public let photoFailures: Int
}

public struct SecureNodeReloadReport: Codable {
    public let attempted: Bool
    public let throttled: Bool
    public let nextAllowedAt: String?
    public let error: String?
}

public struct SecureNodeHealthReport: Codable {
    public let lastSyncAt: String?
    public let lastReloadAt: String?
    public let snapshotVersion: Int?
    public let snapshotCount: Int?
    public let contactsPermission: String
}

