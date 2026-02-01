import Foundation
import CallKit
import os.log
import UIKit
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Logging compatibility shim (iOS 13 support)
fileprivate struct SNLogger {
    #if canImport(os)
    private let oslog: OSLog
    #endif
    init(subsystem: String, category: String) {
        #if canImport(os)
        self.oslog = OSLog(subsystem: subsystem, category: category)
        #endif
    }
    func info(_ message: String) {
        if #available(iOS 14.0, *) {
            // Use new Logger API when available
            let logger = os.Logger(subsystem: "SecureNodeSDK", category: "api")
            logger.info("\(message, privacy: .public)")
        } else {
            // Fallback for iOS 13
            #if canImport(os)
            os_log("%{public}@", log: oslog, type: .info, message)
            #else
            print(message)
            #endif
        }
    }
}

/**
 * SecureNode iOS SDK
 *
 * Provides branding integration for incoming calls via CallKit.
 * Handles local caching, API synchronization, and secure credential storage.
 * Supports BGAppRefreshTask for background sync after app suspend/restart.
 */
public class SecureNodeSDK {
    /// Task identifier for background branding sync. Add this to your app's Info.plist under BGTaskSchedulerPermittedIdentifiers.
    public static let backgroundRefreshTaskIdentifier = "com.securenode.branding.sync"

    #if canImport(BackgroundTasks)
    private static weak var _instanceForBackgroundTask: SecureNodeSDK?
    private static var _backgroundTaskRegistered = false
    #endif

    private let config: SecureNodeConfig
    private let options: SecureNodeOptions
    private let apiClient: ApiClient
    private let database: BrandingDatabase
    private let keychainManager: KeychainManager
    private let imageCache: ImageCache
    private let session: URLSession
    private let trustDelegate: URLSessionDelegate?
    private let runtimeConfig = RuntimeConfigStore()
    private let deviceIdentity = DeviceIdentity()
    private var autoSyncTimer: DispatchSourceTimer?
    private var presenceHeartbeatTimer: DispatchSourceTimer?
    private let staleSeconds: TimeInterval = 24 * 60 * 60
    private let presenceHeartbeatInterval: TimeInterval = 5 * 60

    private static let log = SNLogger(subsystem: "SecureNodeSDK", category: "api")

    /// Invoke optional debug logger on main thread (for app debug UI); also logs to os_log for Console.app.
    private func debugLogLine(_ line: String) {
        Self.log.info(line)
        guard options.debugLog != nil else { return }
        if Thread.isMainThread {
            options.debugLog?(line)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.options.debugLog?(line)
            }
        }
    }

    /**
     * Initialize the SDK
     */
    public convenience init(config: SecureNodeConfig) {
        self.init(config: config, options: SecureNodeOptions())
    }

    /// Initialize the SDK with local feature flags (future-proofing)
    public init(config: SecureNodeConfig, options: SecureNodeOptions) {
        self.config = config
        self.options = options
        
        // Initialize secure key storage
        keychainManager = KeychainManager()
        
        // Retrieve or store API key securely
        if keychainManager.getApiKey() != nil {
            // Use stored key
        } else if !config.apiKey.isEmpty {
            keychainManager.saveApiKey(config.apiKey)
        }
        
        let apiKey = keychainManager.getApiKey() ?? config.apiKey
        
        // Initialize URL session (trust system roots + SecureNode client CA).
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 10
        sessionConfig.timeoutIntervalForResource = 10
        let delegate = SecureNodeTrustDelegate()
        self.trustDelegate = delegate.isEnabled ? delegate : nil
        self.session = URLSession(configuration: sessionConfig, delegate: self.trustDelegate, delegateQueue: nil)
        
        // Initialize API client (default base URL to edge.securenode.io if not set)
        let baseURL: URL = {
            let u = config.apiURL
            guard let host = u.host, !host.isEmpty else { return SecureNodeConfig.defaultBaseURL }
            return u
        }()
        apiClient = ApiClient(baseURL: baseURL, apiKey: apiKey, session: session, debugLog: options.debugLog)

        // Persist local feature flags
        runtimeConfig.setLocalSecureVoiceEnabled(options.enableSecureVoice)

        // Initialize database (single shared instance for process-wide serialized access)
        database = BrandingDatabase.shared

        // Initialize image cache
        imageCache = ImageCache()

        // Register device (best-effort; fail-open) so it appears on the portal.
        let deviceId = deviceIdentity.getOrCreateDeviceId()
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        let deviceTypeDisplay = "\(UIDevice.current.model) (\(osVer.majorVersion).\(osVer.minorVersion))"
        apiClient.registerDevice(
            deviceId: deviceId,
            platform: "ios",
            deviceType: deviceTypeDisplay,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: appVersion,
            sdkVersion: appVersion,
            customerName: options.customerName,
            customerAccountNumber: options.customerAccountNumber
        ) { [weak self] result in
            switch result {
            case .success: self?.debugLogLine("register: ok")
            case .failure(let e): self?.debugLogLine("register: err \(e.localizedDescription)")
            }
            self?.sendDeviceUpdateNow(lastSeen: ISO8601DateFormatter().string(from: Date()))
        }
        // Delayed update so portal sees device even if register completion was slow or update was dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.sendDeviceUpdateNow(lastSeen: ISO8601DateFormatter().string(from: Date()))
        }

        // Clean up old branding data periodically
        cleanupOldBranding()

        // Auto-sync every 30 minutes (best-effort; runs only while the app process is alive).
        startAutoSyncEvery30Minutes()

        // BGAppRefreshTask: register and schedule so sync runs after suspend/restart when system allows.
        registerBackgroundRefreshIfAvailable()
        scheduleBackgroundRefreshIfAvailable()

        // Presence heartbeats: so the API/system knows this device is active.
        startPresenceHeartbeats()

        // Best-effort: flush queued offline events on startup.
        flushPendingEvents()
        flushPendingTelemetry()
    }

    // MARK: - Presence heartbeats

    private func startPresenceHeartbeats() {
        presenceHeartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: presenceHeartbeatInterval, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in
            self?.sendPresenceHeartbeatNow()
        }
        presenceHeartbeatTimer = timer
        timer.resume()
    }

    private func sendPresenceHeartbeatNow() {
        let deviceId = deviceIdentity.getOrCreateDeviceId()
        let observedAt = ISO8601DateFormatter().string(from: Date())
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let lastSyncedAt = runtimeConfig.getLastSyncedAt()
        apiClient.sendPresenceHeartbeat(
            deviceId: deviceId,
            observedAt: observedAt,
            platform: "ios",
            osVersion: osVersion,
            lastSyncedAt: lastSyncedAt
        ) { _ in }
        // Portal "active devices" uses POST /api/mobile/device/update with last_seen (per OpenAPI).
        sendDeviceUpdateNow(lastSeen: observedAt)
    }

    /// Reports lookup result to the API: outcome "displayed" when branding matched, "no_match" when not.
    private func reportLookupOutcome(phoneNumber: String, branding: BrandingInfo) {
        let matched = (branding.brandName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        recordCallEvent(
            phoneNumberE164: phoneNumber,
            outcome: matched ? "displayed" : "no_match",
            surface: "lookup",
            brandingApplied: matched,
            completion: nil
        )
    }

    /// Updates device last_seen and optional capabilities so the portal shows the device as active.
    private func sendDeviceUpdateNow(lastSeen: String? = nil) {
        let deviceId = deviceIdentity.getOrCreateDeviceId()
        let now = lastSeen ?? ISO8601DateFormatter().string(from: Date())
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        var capabilities: [String: Any]? = nil
        #if canImport(BackgroundTasks)
        if #available(iOS 13.0, *) {
            capabilities = ["background_refresh": true]
        }
        #endif
        apiClient.updateDevice(
            deviceId: deviceId,
            platform: "ios",
            osVersion: osVersion,
            appVersion: appVersion,
            sdkVersion: appVersion,
            capabilities: capabilities,
            lastSeen: now
        ) { [weak self] result in
            switch result {
            case .success: self?.debugLogLine("device update: ok")
            case .failure(let e): self?.debugLogLine("device update: err \(e.localizedDescription)")
            }
        }
    }

    // MARK: - Background refresh (iOS 13+). Excluded in app extensions (BGTaskScheduler unavailable).
    #if canImport(BackgroundTasks) && !SECURENODE_APP_EXTENSION
    private func registerBackgroundRefreshIfAvailable() {
        guard #available(iOS 13.0, *) else { return }
        guard !Self._backgroundTaskRegistered else {
            Self._instanceForBackgroundTask = self
            return
        }
        Self._backgroundTaskRegistered = true
        Self._instanceForBackgroundTask = self
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundRefreshTaskIdentifier,
            using: nil
        ) { [weak self] task in
            (self ?? Self._instanceForBackgroundTask)?.performBackgroundSync(task: task as? BGAppRefreshTask)
        }
    }

    private func scheduleBackgroundRefreshIfAvailable() {
        if #available(iOS 13.0, *) {
            let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshTaskIdentifier)
            request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                print("SecureNodeSDK: scheduleBackgroundRefresh failed: \(error.localizedDescription)")
            }
        }
    }

    private func performBackgroundSync(task: BGAppRefreshTask?) {
        let since = runtimeConfig.getLastSyncedAt()
        syncBranding(since: since) { [weak self] result in
            switch result {
            case .success:
                self?.scheduleBackgroundRefreshIfAvailable()
                task?.setTaskCompleted(success: true)
            case .failure:
                task?.setTaskCompleted(success: false)
            }
        }
    }
    #else
    private func registerBackgroundRefreshIfAvailable() {}
    private func scheduleBackgroundRefreshIfAvailable() {}
    #endif
    
    /**
     * Sync branding data from the API
     *
     * - Parameter since: Optional ISO timestamp for incremental sync
     * - Parameter completion: Result callback with SyncResponse or error
     */
    public func syncBranding(
        since: String? = nil,
        completion: @escaping (Result<SyncResponse, Error>) -> Void
    ) {
        syncBrandingImpl(since: since, completion: completion, isRetry: false)
    }

    /// Internal sync with fail-safe: on first failure wipe local DB and retry one full sync.
    private func syncBrandingImpl(
        since: String?,
        completion: @escaping (Result<SyncResponse, Error>) -> Void,
        isRetry: Bool
    ) {
        let startedAt = Date()
        let deviceId = deviceIdentity.getOrCreateDeviceId()
        apiClient.syncBranding(since: since, deviceId: deviceId) { [weak self] result in
            switch result {
            case .success(let response):
                // Store in local database
                if since == nil {
                    self?.database.replaceAllBranding(response.branding)
                } else {
                    self?.database.saveBranding(response.branding)
                }

                // Persist syncedAt for incremental sync (in-app timer and background task).
                self?.runtimeConfig.setLastSyncedAt(response.syncedAt)

                // Presence heartbeat and device/update so the portal shows this device as active.
                self?.sendPresenceHeartbeatNow()
                self?.sendDeviceUpdateNow(lastSeen: response.syncedAt)

                // Persist config (non-breaking) so call handling can gate assistance when capped/disabled.
                if let cfg = response.config {
                    self?.runtimeConfig.setBrandingEnabled(cfg.brandingEnabled ?? true)
                    if let voip = cfg.voipDialerEnabled {
                        self?.runtimeConfig.setServerSecureVoiceEnabled(voip)
                    }
                }

                // Schedule next background refresh when running in foreground.
                self?.scheduleBackgroundRefreshIfAvailable()

                // Pre-cache images in background
                response.branding.forEach { branding in
                    if let logoUrl = branding.logoUrl {
                        self?.imageCache.loadImageAsync(from: logoUrl) { _ in }
                    }
                }

                // Best-effort: flush queued offline events after successful sync.
                self?.flushPendingEvents()
                self?.flushPendingTelemetry()

                self?.trackTelemetry(
                    eventName: "sync",
                    level: "info",
                    message: "success",
                    meta: [
                        "success": true,
                        "partial": since != nil,
                        "items_updated": response.branding.count,
                        "latency_ms": Int(Date().timeIntervalSince(startedAt) * 1000)
                    ]
                )

                // POST sync ack so server knows sync was applied (OpenAPI: last_synced_at, optional e164_numbers).
                let e164s = response.branding.map(\.phoneNumberE164)
                self?.apiClient.syncAck(lastSyncedAt: response.syncedAt, e164Numbers: e164s.isEmpty ? nil : e164s) { [weak self] result in
                    switch result {
                    case .success: self?.debugLogLine("sync ack: ok")
                    case .failure(let e): self?.debugLogLine("sync ack: err \(e.localizedDescription)")
                    }
                }

                // POST debug/upload only when sync config.debug_ui allows (request_upload + allow_export).
                if let debugUi = response.config?.debugUi, debugUi.requestUpload == true, debugUi.allowExport == true {
                    self?.apiClient.uploadDebug(deviceId: deviceId, nonce: UUID().uuidString) { _ in }
                }

                // Call Directory: write snapshot and reload so dialer/missed-call show branding (when app group + extension configured).
                self?.writeCallDirectorySnapshotAndReloadIfConfigured(branding: response.branding, sinceCursor: response.syncedAt)
                // Contacts: grouped by branding profile, incremental; one contact per brand with up to N numbers.
                self?.syncManagedContactsIfConfigured(branding: response.branding)

                completion(.success(response))
            case .failure(let error):
                self?.trackTelemetry(
                    eventName: "sync",
                    level: "warn",
                    message: "failed",
                    meta: [
                        "success": false,
                        "partial": since != nil,
                        "latency_ms": Int(Date().timeIntervalSince(startedAt) * 1000),
                        "error": error.localizedDescription
                    ]
                )
                if !isRetry {
                    self?.database.resetAllData()
                    self?.syncBrandingImpl(since: nil, completion: completion, isRetry: true)
                } else {
                    completion(.failure(error))
                }
            }
        }
    }

    /// When appGroupId is set, syncs Contacts grouped by branding profile (one contact per brand, up to N numbers per contact); incremental via registry.
    private func syncManagedContactsIfConfigured(branding: [BrandingInfo]) {
        guard let group = config.appGroupId, !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let maxProfiles = config.maxManagedContactProfiles
        let maxNumbers = config.maxPhoneNumbersPerContact
        Task {
            do {
                let sync = ManagedContactsSync(appGroupId: group)
                let result = try await sync.syncManagedContacts(branding: branding, maxProfiles: maxProfiles, maxPhoneNumbersPerContact: maxNumbers)
                await MainActor.run { [weak self] in
                    self?.debugLogLine("contacts sync: ok upserted \(result.upserted) deleted \(result.deleted) photos \(result.photosApplied)")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.debugLogLine("contacts sync: err \(error.localizedDescription)")
                }
            }
        }
    }

    /// When appGroupId + callDirectoryExtensionBundleId are set, writes snapshot to App Group and reloads Call Directory so dialer/missed-call show branding and OS bypasses unknown/spam filtering.
    private func writeCallDirectorySnapshotAndReloadIfConfigured(branding: [BrandingInfo], sinceCursor: String?) {
        guard let group = config.appGroupId, let extId = config.callDirectoryExtensionBundleId,
              !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !extId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let maxActive = 5000
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let store = SecureNodeAppGroupStore(appGroupId: group)
                let entries = SecureNodeDirectoryBuilder.buildSnapshotEntries(from: branding, maxActiveNumbers: maxActive)
                _ = try store.writeSnapshot(entries: entries, sinceCursor: sinceCursor)
                DispatchQueue.main.async {
                    CXCallDirectoryManager.sharedInstance.reloadExtension(withIdentifier: extId) { [weak self] err in
                        if let err = err {
                            let ns = err as NSError
                            if ns.domain == "com.apple.CallKit.error.calldirectorymanager", ns.code == 6 {
                                self?.debugLogLine("call directory reload: extension not enabled (Settings > Phone > Call Blocking & Identification)")
                            } else {
                                self?.debugLogLine("call directory reload: err \(err.localizedDescription)")
                            }
                        } else {
                            self?.debugLogLine("call directory reload: ok \(entries.count) entries")
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.debugLogLine("call directory snapshot: err \(error.localizedDescription)")
                }
            }
        }
    }

    private func startAutoSyncEvery30Minutes() {
        autoSyncTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        // Start a few seconds after init, then every 30 minutes.
        timer.schedule(deadline: .now() + 5, repeating: 30 * 60, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in
            let since = self?.runtimeConfig.getLastSyncedAt()
            self?.syncBranding(since: since) { _ in
                // ignore
            }
        }
        autoSyncTimer = timer
        timer.resume()
    }
    
    /**
     * List all synced branding entries (from local cache). For demo/debug UI.
     */
    public func listSyncedBranding(limit: Int = 500) -> [BrandingInfo] {
        database.listAllBranding(limit: limit)
    }

    /**
     * Get branding for a specific phone number
     *
     * - Parameter phoneNumber: E.164 formatted phone number
     * - Parameter completion: Result callback with BrandingInfo or error
     */
    public func getBranding(
        for phoneNumber: String,
        completion: @escaping (Result<BrandingInfo, Error>) -> Void
    ) {
        let startedAt = Date()
        // First try local database
        if let cached = database.getBranding(for: phoneNumber) {
            let df = ISO8601DateFormatter()
            let cachedDate = df.date(from: cached.updatedAt) ?? Date()
            let ageMs = Int(Date().timeIntervalSince(cachedDate) * 1000)
            let stale = Date().timeIntervalSince(cachedDate) > staleSeconds
            trackTelemetry(
                eventName: "identity_lookup",
                level: "info",
                message: "cache_hit",
                meta: [
                    "cache_status": stale ? "stale" : "hit",
                    "cache_age_ms": ageMs,
                    "brand_id": cached.brandId as Any,
                    "brand_elements_supplied": [
                        "name": cached.brandName != nil,
                        "logo": cached.logoUrl != nil,
                        "reason": cached.callReason != nil
                    ],
                    "latency_ms": Int(Date().timeIntervalSince(startedAt) * 1000)
                ]
            )
            reportLookupOutcome(phoneNumber: phoneNumber, branding: cached)
            completion(.success(cached))
            return
        }
        
        // Fallback to API lookup
        let deviceId = deviceIdentity.getOrCreateDeviceId()
        apiClient.lookupBranding(phoneNumber: phoneNumber, deviceId: deviceId) { [weak self] result in
            switch result {
            case .success(let brandingOpt):
                if let branding = brandingOpt, branding.brandName != nil {
                    // Cache for next time
                    self?.database.saveBranding([branding])
                    self?.trackTelemetry(
                        eventName: "identity_lookup",
                        level: "info",
                        message: "network_hit",
                        meta: [
                            "cache_status": "miss",
                            "cache_age_ms": NSNull(),
                            "brand_id": branding.brandId as Any,
                            "brand_elements_supplied": [
                                "name": branding.brandName != nil,
                                "logo": branding.logoUrl != nil,
                                "reason": branding.callReason != nil
                            ],
                            "latency_ms": Int(Date().timeIntervalSince(startedAt) * 1000)
                        ]
                    )
                    self?.reportLookupOutcome(phoneNumber: phoneNumber, branding: branding)
                    completion(.success(branding))
                } else {
                    self?.trackTelemetry(
                        eventName: "identity_lookup",
                        level: "info",
                        message: "no_match",
                        meta: [
                            "cache_status": "miss",
                            "latency_ms": Int(Date().timeIntervalSince(startedAt) * 1000)
                        ]
                    )
                    let noMatch = BrandingInfo(
                        phoneNumberE164: phoneNumber,
                        brandName: nil,
                        logoUrl: nil,
                        callReason: nil,
                        brandId: nil,
                        updatedAt: ""
                    )
                    self?.reportLookupOutcome(phoneNumber: phoneNumber, branding: noMatch)
                    completion(.success(noMatch))
                }
            case .failure(let error):
                self?.trackTelemetry(
                    eventName: "identity_lookup",
                    level: "warn",
                    message: "failed",
                    meta: [
                        "error": error.localizedDescription
                    ]
                )
                completion(.failure(error))
            }
        }
    }

    // Identity-only telemetry
    public func trackTelemetry(eventName: String, level: String, message: String, meta: [String: Any] = [:]) {
        let deviceId = deviceIdentity.getOrCreateDeviceId()
        let occurredAt = ISO8601DateFormatter().string(from: Date())

        apiClient.sendDeviceLog(
            deviceId: deviceId,
            level: level,
            message: "\(eventName):\(message)",
            meta: ["event": eventName].merging(meta) { _, new in new },
            occurredAt: occurredAt
        ) { [weak self] result in
            if case .failure = result {
                let metaJson: String? = (try? JSONSerialization.data(withJSONObject: ["event": eventName].merging(meta) { _, new in new }))
                    .flatMap { String(data: $0, encoding: .utf8) }
                self?.database.insertPendingTelemetry(level: level, message: "\(eventName):\(message)", metaJson: metaJson, occurredAt: occurredAt)
                self?.database.prunePendingTelemetry(olderThanDays: 7)
            }
        }
    }

    private func flushPendingTelemetry(limit: Int = 50) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let deviceId = self.deviceIdentity.getOrCreateDeviceId()
            let rows = self.database.listPendingTelemetry(limit: limit)
            guard !rows.isEmpty else { return }

            var sentIds: [Int64] = []
            let group = DispatchGroup()

            for r in rows {
                var meta: [String: Any]? = nil
                if let metaJson = r.metaJson, let data = metaJson.data(using: .utf8) {
                    meta = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                }

                group.enter()
                self.apiClient.sendDeviceLog(
                    deviceId: deviceId,
                    level: r.level,
                    message: r.message,
                    meta: meta,
                    occurredAt: r.occurredAt
                ) { result in
                    if case .success = result {
                        sentIds.append(r.id)
                    }
                    group.leave()
                }
                group.wait()
                if sentIds.last != r.id { break }
            }

            if !sentIds.isEmpty {
                self.database.deletePendingTelemetry(ids: sentIds)
            }
        }
    }

    private func buildEventMeta(
        base: [String: Any]?,
        callEventId: String?,
        deviceId: String,
        observedAt: String,
        platform: String,
        extras: [String: Any] = [:]
    ) -> [String: Any]? {
        var meta = base ?? [:]
        for (key, value) in extras {
            if meta[key] == nil {
                meta[key] = value
            }
        }
        if meta["call_event_id"] == nil, let callEventId = callEventId, !callEventId.isEmpty {
            meta["call_event_id"] = callEventId
        }
        if meta["device_id"] == nil {
            meta["device_id"] = deviceId
        }
        if meta["platform"] == nil {
            meta["platform"] = platform
        }
        if meta["observed_at_utc"] == nil {
            meta["observed_at_utc"] = observedAt
        }
        return meta.isEmpty ? nil : meta
    }

    private func encodeMetaJson(_ meta: [String: Any]?) -> String? {
        guard let meta = meta, !meta.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: meta) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /**
     * Record a ring-time event for an incoming call.
     *
     * If offline, we queue it locally and flush on the next sync/interval.
     */
    public func recordCallEvent(
        phoneNumberE164: String,
        outcome: String,
        surface: String = "callkit",
        displayedAt: String? = nil,
        observedAtUtc: String? = nil,
        callEventId: String? = nil,
        callerNumberE164: String? = nil,
        destinationNumberE164: String? = nil,
        brandingApplied: Bool? = nil,
        brandingProfileId: String? = nil,
        identityType: String? = nil,
        ringDurationSeconds: Int? = nil,
        callDurationSeconds: Int? = nil,
        callOutcome: String? = nil,
        returnCallDetected: Bool? = nil,
        returnCallLatencySeconds: Int? = nil,
        trackingMeta: [String: Any]? = nil,
        completion: ((Result<BrandingEventResponse, Error>) -> Void)? = nil
    ) {
        let deviceId = deviceIdentity.getOrCreateDeviceId()
        let observedAt = (observedAtUtc?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? observedAtUtc : nil)
            ?? displayedAt
            ?? ISO8601DateFormatter().string(from: Date())
        let normalizedCallEventId = callEventId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let metaCallEventId = (trackingMeta?["call_event_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let eventKey = (normalizedCallEventId?.isEmpty == false ? normalizedCallEventId : (metaCallEventId?.isEmpty == false ? metaCallEventId : "call_event:\(UUID().uuidString)")) ?? ""
        var extras: [String: Any] = [:]
        if let value = callerNumberE164?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            extras["caller_number_e164"] = value
        }
        if let value = destinationNumberE164?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            extras["destination_number_e164"] = value
        }
        if let brandingApplied = brandingApplied {
            extras["branding_applied"] = brandingApplied
            extras["branded"] = brandingApplied  // If branding is displayed, we say it was branded.
        }
        if let value = brandingProfileId?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            extras["branding_profile_id"] = value
        }
        if let value = identityType?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            extras["identity_type"] = value
        }
        if let ringDurationSeconds = ringDurationSeconds {
            extras["ring_duration_seconds"] = ringDurationSeconds
        }
        if let callDurationSeconds = callDurationSeconds {
            extras["call_duration_seconds"] = callDurationSeconds
        }
        if let value = callOutcome?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            extras["call_outcome"] = value
        }
        if let returnCallDetected = returnCallDetected {
            extras["return_call_detected"] = returnCallDetected
        }
        if let returnCallLatencySeconds = returnCallLatencySeconds {
            extras["return_call_latency_seconds"] = returnCallLatencySeconds
        }
        let meta = buildEventMeta(
            base: trackingMeta,
            callEventId: eventKey,
            deviceId: deviceId,
            observedAt: observedAt,
            platform: "ios",
            extras: extras
        )

        apiClient.recordEvent(
            phoneNumberE164: phoneNumberE164,
            outcome: outcome,
            surface: surface,
            displayedAt: observedAt,
            deviceId: deviceId,
            eventKey: eventKey,
            meta: meta
        ) { [weak self] result in
            switch result {
            case .success(let resp):
                self?.debugLogLine("event: \(outcome) ok")
                if let enabled = resp.config?.brandingEnabled {
                    self?.runtimeConfig.setBrandingEnabled(enabled)
                }
                completion?(.success(resp))
            case .failure(let err):
                self?.debugLogLine("event: err \(err.localizedDescription)")
                let iso = observedAt
                self?.database.insertPendingEvent(
                    phoneNumberE164: phoneNumberE164,
                    outcome: outcome,
                    surface: surface,
                    displayedAt: iso,
                    eventKey: eventKey,
                    metaJson: self?.encodeMetaJson(meta)
                )
                self?.database.prunePendingEvents(olderThanDays: 7)
                completion?(.failure(err))
            }
        }

    }

    /**
     * Baseline "seen" event when identity is displayed. Returns event_id (call_id) in response.
     * Use call_outcome values your exports expect (e.g. ANSWERED, MISSED, REJECTED).
     */
    public func recordCallSeen(
        phoneNumberE164: String,
        brandingDisplayed: Bool = true,
        callOutcome: String? = nil,
        ringDurationSeconds: Int? = nil,
        callDurationSeconds: Int? = nil,
        callerNumberE164: String? = nil,
        destinationNumberE164: String? = nil,
        completion: ((Result<BrandingEventResponse, Error>) -> Void)? = nil
    ) {
        recordCallEvent(
            phoneNumberE164: phoneNumberE164,
            outcome: brandingDisplayed ? "displayed" : "no_match",
            surface: "display",
            callerNumberE164: callerNumberE164 ?? phoneNumberE164,
            destinationNumberE164: destinationNumberE164,
            brandingApplied: brandingDisplayed,
            ringDurationSeconds: ringDurationSeconds,
            callDurationSeconds: callDurationSeconds,
            callOutcome: callOutcome,
            completion: completion
        )
    }

    /**
     * Missed-call outcome. Report via /mobile/branding/event.
     */
    public func recordMissedCall(
        phoneNumberE164: String,
        callerNumberE164: String? = nil,
        destinationNumberE164: String? = nil,
        completion: ((Result<BrandingEventResponse, Error>) -> Void)? = nil
    ) {
        recordCallEvent(
            phoneNumberE164: phoneNumberE164,
            outcome: "missed",
            surface: "display",
            callerNumberE164: callerNumberE164 ?? phoneNumberE164,
            destinationNumberE164: destinationNumberE164,
            completion: completion
        )
    }

    /**
     * Follow-up attribution when the user returns the call. Pass the earlier call_id from recordCallSeen/recordMissedCall.
     */
    public func recordCallReturned(
        phoneNumberE164: String,
        callId: String,
        returnCallLatencySeconds: Int? = nil,
        completion: ((Result<BrandingEventResponse, Error>) -> Void)? = nil
    ) {
        recordCallEvent(
            phoneNumberE164: phoneNumberE164,
            outcome: "returned",
            surface: "display",
            callEventId: callId,
            returnCallDetected: true,
            returnCallLatencySeconds: returnCallLatencySeconds,
            completion: completion
        )
    }

    private func flushPendingEvents(limit: Int = 50) {
        // Best-effort; do not block UI.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let rows = self.database.listPendingEvents(limit: limit)
            guard !rows.isEmpty else { return }

            var sentIds: [Int64] = []
            let group = DispatchGroup()

            // Send sequentially to keep it simple.
            for r in rows {
                let deviceId = self.deviceIdentity.getOrCreateDeviceId()
                var parsedMeta: [String: Any]? = nil
                if let metaJson = r.metaJson, let data = metaJson.data(using: .utf8) {
                    parsedMeta = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                }
                let mergedMeta = self.buildEventMeta(
                    base: parsedMeta,
                    callEventId: r.eventKey,
                    deviceId: deviceId,
                    observedAt: r.displayedAt,
                    platform: "ios"
                )
                group.enter()
                self.apiClient.recordEvent(
                    phoneNumberE164: r.phoneNumberE164,
                    outcome: r.outcome,
                    surface: r.surface,
                    displayedAt: r.displayedAt,
                    deviceId: deviceId,
                    eventKey: r.eventKey,
                    meta: mergedMeta
                ) { result in
                    if case .success = result {
                        sentIds.append(r.id)
                    }
                    group.leave()
                }
                group.wait()
                // If one fails, stop and retry later.
                if sentIds.last != r.id {
                    break
                }
            }

            if !sentIds.isEmpty {
                self.database.deletePendingEvents(ids: sentIds)
            }
        }
    }

    /**
     * Convenience: apply SecureNode branding for an incoming call and emit billing event when assisted.
     *
     * Intended for VoIP/CallKit flows where your app owns the call event.
     * - If branding is disabled by server policy/caps, we report the call without branding and do NOT bill.
     */
    public func assistIncomingCall(
        uuid: UUID,
        phoneNumber: String,
        provider: CXProvider,
        completion: ((Error?) -> Void)? = nil
    ) {
        let enabled = runtimeConfig.isBrandingEnabled()

        // Always report the call; branding is optional.
        func report(update: CXCallUpdate, assisted: Bool) {
            provider.reportNewIncomingCall(with: uuid, update: update) { err in
                if assisted && err == nil {
                    self.recordCallEvent(phoneNumberE164: phoneNumber, outcome: "assisted", surface: "callkit", completion: nil)
                    // Best-effort: imprint for per-device activity (never blocks call UX)
                    let deviceId = self.deviceIdentity.getOrCreateDeviceId()
                    let osVersion = UIDevice.current.systemVersion
                    let deviceModel = self.sha256Hex(UIDevice.current.model)
                    self.apiClient.recordImprint(
                        deviceId: deviceId,
                        phoneNumberE164: phoneNumber,
                        platform: "ios",
                        osVersion: osVersion,
                        deviceModel: deviceModel,
                        campaignId: self.config.campaignId
                    ) { _ in
                        // ignore
                    }
                }
                if assisted {
                    self.trackTelemetry(
                        eventName: "branding_applied_attempt",
                        level: err == nil ? "info" : "warn",
                        message: "attempt",
                        meta: [
                            "surface": "callkit",
                            "os_integration": "CallKit",
                            "os_response": err == nil ? "accepted" : "ignored",
                            "brand_elements_supplied": [
                                "name": update.localizedCallerName != nil,
                                "logo": false,
                                "reason": false
                            ]
                        ]
                    )
                }
                completion?(err)
            }
        }

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: phoneNumber)

        guard enabled else {
            update.localizedCallerName = phoneNumber
            report(update: update, assisted: false)
            return
        }

        getBranding(for: phoneNumber) { result in
            switch result {
            case .success(let branding):
                if let name = branding.brandName, !name.isEmpty {
                    update.localizedCallerName = name
                    report(update: update, assisted: true)
                } else {
                    update.localizedCallerName = phoneNumber
                    report(update: update, assisted: false)
                }
            case .failure:
                update.localizedCallerName = phoneNumber
                report(update: update, assisted: false)
            }
        }
    }

    /// Returns true only when local + server gates allow Secure Voice (VoIP/SIP) channel.
    public func isSecureVoiceEnabled() -> Bool {
        return runtimeConfig.isLocalSecureVoiceEnabled() && runtimeConfig.isServerSecureVoiceEnabled()
    }
    
    /**
     * Remove all cached branding images. Use to free space or reset cache per spec.
     */
    public func clearImageCache() {
        imageCache.clearCache()
    }

    /**
     * Clean up old branding data (older than retention period)
     */
    private func cleanupOldBranding() {
        let retentionDays: TimeInterval = 30 * 24 * 60 * 60
        let cutoffTime = Date().addingTimeInterval(-retentionDays)
        database.deleteOldBranding(before: cutoffTime)
        imageCache.cleanupOldImages()
    }

    private func sha256Hex(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        #if canImport(CryptoKit)
        if #available(iOS 13.0, *) {
            let digest = SHA256.hash(data: Data(trimmed.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        #endif
        return nil
    }
}

/// URLSessionDelegate that trusts the platform roots plus the SecureNode client CA (prod-ca-2021).
final class SecureNodeTrustDelegate: NSObject, URLSessionDelegate {
    private let anchor: SecCertificate?

    var isEnabled: Bool { anchor != nil }

    override init() {
        // DER base64 for prod-ca-2021 (no BEGIN/END lines)
        let b64 =
            "MIIDxDCCAqygAwIBAgIUbLxMod62P2ktCiAkxnKJwtE9VPYwDQYJKoZIhvcNAQEL" +
            "BQAwazELMAkGA1UEBhMCVVMxEDAOBgNVBAgMB0RlbHdhcmUxEzARBgNVBAcMCk5l" +
            "dyBDYXN0bGUxFTATBgNVBAoMDFN1cGFiYXNlIEluYzEeMBwGA1UEAwwVU3VwYWJh" +
            "c2UgUm9vdCAyMDIxIENBMB4XDTIxMDQyODEwNTY1M1oXDTMxMDQyNjEwNTY1M1ow" +
            "azELMAkGA1UEBhMCVVMxEDAOBgNVBAgMB0RlbHdhcmUxEzARBgNVBAcMCk5ldyBD" +
            "YXN0bGUxFTATBgNVBAoMDFN1cGFiYXNlIEluYzEeMBwGA1UEAwwVU3VwYWJhc2Ug" +
            "Um9vdCAyMDIxIENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqQXW" +
            "QyHOB+qR2GJobCq/CBmQ40G0oDmCC3mzVnn8sv4XNeWtE5XcEL0uVih7Jo4Dkx1Q" +
            "DmGHBH1zDfgs2qXiLb6xpw/CKQPypZW1JssOTMIfQppNQ87K75Ya0p25Y3ePS2t2" +
            "GtvHxNjUV6kjOZjEn2yWEcBdpOVCUYBVFBNMB4YBHkNRDa/+S4uywAoaTWnCJLUi" +
            "cvTlHmMw6xSQQn1UfRQHk50DMCEJ7Cy1RxrZJrkXXRP3LqQL2ijJ6F4yMfh+Gyb4" +
            "O4XajoVj/+R4GwywKYrrS8PrSNtwxr5StlQO8zIQUSMiq26wM8mgELFlS/32Uclt" +
            "NaQ1xBRizkzpZct9DwIDAQABo2AwXjALBgNVHQ8EBAMCAQYwHQYDVR0OBBYEFKjX" +
            "uXY32CztkhImng4yJNUtaUYsMB8GA1UdIwQYMBaAFKjXuXY32CztkhImng4yJNUt" +
            "aUYsMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAB8spzNn+4VU" +
            "tVxbdMaX+39Z50sc7uATmus16jmmHjhIHz+l/9GlJ5KqAMOx26mPZgfzG7oneL2b" +
            "VW+WgYUkTT3XEPFWnTp2RJwQao8/tYPXWEJDc0WVQHrpmnWOFKU/d3MqBgBm5y+6" +
            "jB81TU/RG2rVerPDWP+1MMcNNy0491CTL5XQZ7JfDJJ9CCmXSdtTl4uUQnSuv/Qx" +
            "Cea13BX2ZgJc7Au30vihLhub52De4P/4gonKsNHYdbWjg7OWKwNv/zitGDVDB9Y2" +
            "CMTyZKG3XEu5Ghl1LEnI3QmEKsqaCLv12BnVjbkSeZsMnevJPs1Ye6TjjJwdik5P" +
            "o/bKiIz+Fq8="

        if let data = Data(base64Encoded: b64),
           let cert = SecCertificateCreateWithData(nil, data as CFData) {
            self.anchor = cert
        } else {
            self.anchor = nil
        }
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust,
            let anchor = anchor
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Add our CA, but still allow system roots too.
        SecTrustSetAnchorCertificates(serverTrust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(serverTrust, false)

        if SecTrustEvaluateWithError(serverTrust, nil) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/**
 * SDK Configuration
 */
public struct SecureNodeConfig {
    /// Default base URL when apiURL is not set or invalid (authoritative: mobile-sdk-endpoints.md).
    public static let defaultBaseURL: URL = URL(string: "https://api.securenode.io")!

    public let apiURL: URL
    public let apiKey: String
    public let campaignId: String?
    /// App Group ID for Call Directory snapshot (dialer/missed-call branding). Set with callDirectoryExtensionBundleId to enable.
    public let appGroupId: String?
    /// Call Directory extension bundle ID (e.g. com.yourapp.SecureNode.CallDirectory). Required for dialer branding.
    public let callDirectoryExtensionBundleId: String?
    /// Max managed contacts (grouped by branding profile). One contact per brand, up to maxPhoneNumbersPerContact numbers per contact. Default 1500.
    public let maxManagedContactProfiles: Int
    /// Max phone numbers per managed contact (same branding profile). Default 50.
    public let maxPhoneNumbersPerContact: Int

    public init(apiURL: URL, apiKey: String = "", campaignId: String? = nil, appGroupId: String? = nil, callDirectoryExtensionBundleId: String? = nil, maxManagedContactProfiles: Int = 1500, maxPhoneNumbersPerContact: Int = 50) {
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.campaignId = campaignId
        self.appGroupId = appGroupId
        self.callDirectoryExtensionBundleId = callDirectoryExtensionBundleId
        self.maxManagedContactProfiles = max(1, min(maxManagedContactProfiles, 5000))
        self.maxPhoneNumbersPerContact = max(1, min(maxPhoneNumbersPerContact, 100))
    }
}

/**
 * Minimal local config gate (used to avoid giving free "assistance" when server caps disable branding).
 */
final class RuntimeConfigStore {
    private let defaults = UserDefaults.standard
    private let keyBrandingEnabled = "securenode_branding_enabled"
    private let keyServerSecureVoiceEnabled = "securenode_server_secure_voice_enabled"
    private let keyLocalSecureVoiceEnabled = "securenode_local_secure_voice_enabled"
    private let keyLastSyncedAt = "securenode_branding_last_synced_at"

    func isBrandingEnabled() -> Bool {
        // Default allow until server tells us otherwise.
        if defaults.object(forKey: keyBrandingEnabled) == nil { return true }
        return defaults.bool(forKey: keyBrandingEnabled)
    }

    func setBrandingEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: keyBrandingEnabled)
    }

    func isServerSecureVoiceEnabled() -> Bool {
        if defaults.object(forKey: keyServerSecureVoiceEnabled) == nil { return false }
        return defaults.bool(forKey: keyServerSecureVoiceEnabled)
    }

    func setServerSecureVoiceEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: keyServerSecureVoiceEnabled)
    }

    func isLocalSecureVoiceEnabled() -> Bool {
        if defaults.object(forKey: keyLocalSecureVoiceEnabled) == nil { return false }
        return defaults.bool(forKey: keyLocalSecureVoiceEnabled)
    }

    func setLocalSecureVoiceEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: keyLocalSecureVoiceEnabled)
    }

    func getLastSyncedAt() -> String? {
        defaults.string(forKey: keyLastSyncedAt)
    }

    func setLastSyncedAt(_ iso: String) {
        defaults.set(iso, forKey: keyLastSyncedAt)
    }
}

