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
        // Keep existing trust behavior (system roots + SecureNode CA) for parity with the older SDK.
        let trust = SecureNodeTrustDelegate()
        self.session = URLSession(configuration: sessionConfig, delegate: trust.isEnabled ? trust : nil, delegateQueue: nil)

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
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            sdkVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
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
        // Best-effort device update (idempotent; never blocks sync success).
        postDeviceUpdateBestEffort()

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

    private func postDeviceUpdateBestEffort() {
        let deviceId = deviceIdentity.getOrCreateDeviceId()
        let os = "\(ProcessInfo.processInfo.operatingSystemVersionString)"
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let sdkVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

        // contacts_enabled is authoritative (permission gate)
        let contactsEnabled = (CNContactStore.authorizationStatus(for: .contacts) == .authorized)

        CXCallDirectoryManager.sharedInstance.getEnabledStatusForExtension(withIdentifier: config.callDirectoryExtensionBundleId) { status, _ in
            let callDirEnabled: Bool? = (status == .enabled)

            let caps: [String: Any] = [
                "contacts_enabled": contactsEnabled,
                "call_directory_enabled": callDirEnabled as Any
            ]

            self.apiClient.updateDevice(
                deviceId: deviceId,
                platform: "ios",
                osVersion: os,
                appVersion: appVersion,
                sdkVersion: sdkVersion,
                capabilities: caps,
                lastSeen: ISO8601DateFormatter().string(from: Date())
            ) { _ in
                // ignore
            }
        }
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
        let result: SecureNodeReloadReport = try await withCheckedThrowingContinuation { cont in
            CXCallDirectoryManager.sharedInstance.reloadExtension(withIdentifier: bundleId) { err in
                if let err = err {
                    cont.resume(returning: SecureNodeReloadReport(
                        attempted: true,
                        throttled: false,
                        nextAllowedAt: nil,
                        error: err.localizedDescription
                    ))
                    return
                }
                cont.resume(returning: SecureNodeReloadReport(
                    attempted: true,
                    throttled: false,
                    nextAllowedAt: nil,
                    error: nil
                ))
            }
        }
        if result.error != nil {
            reloadPolicy.recordReloadFailureNow()
            return SecureNodeReloadReport(
                attempted: true,
                throttled: false,
                nextAllowedAt: reloadPolicy.nextAllowedAtIso(),
                error: result.error
            )
        }
        reloadPolicy.recordReloadSuccessNow()
        return result
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

