import Foundation
import CallKit
import Contacts

final class SecureNodeCore {
    private let config: SecureNodeHeadlessConfig
    private let deviceIdentity = DeviceIdentity()
    private let keychain = KeychainManager()
    private let session: URLSession
    private let apiClient: ApiClient

    private let store: SecureNodeAppGroupStore
    private let reloadPolicy: CallDirectoryReloadPolicy
    private let contactsSync: ManagedContactsSync

    init(config: SecureNodeHeadlessConfig) {
        self.config = config

        // Persist key once; do not require host to pass it on every launch.
        if keychain.getApiKey() == nil, !config.apiKey.isEmpty {
            keychain.saveApiKey(config.apiKey)
        }
        let apiKey = keychain.getApiKey() ?? config.apiKey

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 15
        sessionConfig.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: sessionConfig)

        self.apiClient = ApiClient(baseURL: config.apiURL, apiKey: apiKey, session: session)
        self.store = SecureNodeAppGroupStore(appGroupId: config.appGroupId)
        self.reloadPolicy = CallDirectoryReloadPolicy(appGroupId: config.appGroupId)
        self.contactsSync = ManagedContactsSync(appGroupId: config.appGroupId)

        // Best-effort device registration (does not block).
        let deviceId = deviceIdentity.getOrCreateDeviceId()
        apiClient.registerDevice(
            deviceId: deviceId,
            platform: "ios",
            deviceType: nil,
            osVersion: "\(ProcessInfo.processInfo.operatingSystemVersionString)",
            appVersion: nil,
            sdkVersion: nil,
            customerName: nil,
            customerAccountNumber: nil
        ) { _ in }
    }

    func sync() async throws -> SecureNodeSyncReport {
        let current = try store.readCurrentPointer()
        let since = current?.sinceCursor

        let deviceId = deviceIdentity.getOrCreateDeviceId()
        let response = try await withCheckedThrowingContinuation { cont in
            apiClient.syncBranding(since: since, deviceId: deviceId) { result in
                cont.resume(with: result)
            }
        }

        // Build and store the snapshot (active set only, bounded).
        let active = SecureNodeDirectoryBuilder.buildSnapshotEntries(
            from: response.branding,
            maxActiveNumbers: config.maxActiveNumbers
        )
        let pointer = try store.writeSnapshot(entries: active, sinceCursor: response.syncedAt)

        // Contacts: attempted when permission granted or not determined (prompt).
        let contactsResult = try await contactsSync.syncManagedContacts(
            branding: response.branding,
            maxProfiles: config.maxManagedContactProfiles,
            maxPhoneNumbersPerContact: config.maxPhoneNumbersPerManagedContact
        )

        // Reload policy is not automatic: host explicitly calls reloadCallDirectoryIfNeeded().
        // But we update health state.
        reloadPolicy.recordLastSyncNow()

        return SecureNodeSyncReport(
            syncedAt: response.syncedAt,
            receivedCount: response.branding.count,
            activeCount: active.count,
            snapshotVersion: pointer.version,
            contactsPermission: contactsResult.permission,
            managedContactsUpserted: contactsResult.upserted,
            managedContactsDeleted: contactsResult.deleted,
            photosApplied: contactsResult.photosApplied,
            photoFailures: contactsResult.photoFailures
        )
    }

    func reloadCallDirectoryIfNeeded() async throws -> SecureNodeReloadReport {
        let status = reloadPolicy.shouldReloadNow()
        if !status.allowed {
            return SecureNodeReloadReport(
                attempted: false,
                throttled: true,
                nextAllowedAt: status.nextAllowedAt,
                error: nil
            )
        }

        let bundleId = config.callDirectoryExtensionBundleId
        return try await withCheckedThrowingContinuation { cont in
            CXCallDirectoryManager.sharedInstance.reloadExtension(withIdentifier: bundleId) { err in
                if let err = err {
                    self.reloadPolicy.recordReloadFailureNow()
                    cont.resume(returning: SecureNodeReloadReport(
                        attempted: true,
                        throttled: false,
                        nextAllowedAt: self.reloadPolicy.nextAllowedAtIso(),
                        error: err.localizedDescription
                    ))
                    return
                }
                self.reloadPolicy.recordReloadSuccessNow()
                cont.resume(returning: SecureNodeReloadReport(
                    attempted: true,
                    throttled: false,
                    nextAllowedAt: nil,
                    error: nil
                ))
            }
        }
    }

    func health() -> SecureNodeHealthReport {
        let pointer = try? store.readCurrentPointer()
        let contactsPermission = ManagedContactsSync.contactsPermissionString()
        return SecureNodeHealthReport(
            lastSyncAt: reloadPolicy.lastSyncAtIso(),
            lastReloadAt: reloadPolicy.lastReloadAtIso(),
            snapshotVersion: pointer?.version,
            snapshotCount: pointer?.count,
            contactsPermission: contactsPermission
        )
    }
}

