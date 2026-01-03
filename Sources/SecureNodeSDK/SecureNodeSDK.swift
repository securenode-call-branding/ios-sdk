import Foundation
import CallKit

/**
 * SecureNode iOS SDK
 *
 * Provides branding integration for incoming calls via CallKit.
 * Handles local caching, API synchronization, and secure credential storage.
 */
public class SecureNodeSDK {
    private let config: SecureNodeConfig
    private let options: SecureNodeOptions
    private let apiClient: ApiClient
    private let database: BrandingDatabase
    private let keychainManager: KeychainManager
    private let imageCache: ImageCache
    private let session: URLSession
    private let runtimeConfig = RuntimeConfigStore()
    private let deviceIdentity = DeviceIdentity()
    private var autoSyncTimer: DispatchSourceTimer?
    private let staleSeconds: TimeInterval = 24 * 60 * 60
    
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
        if let storedApiKey = keychainManager.getApiKey() {
            // Use stored key
        } else if !config.apiKey.isEmpty {
            keychainManager.saveApiKey(config.apiKey)
        }
        
        let apiKey = keychainManager.getApiKey() ?? config.apiKey
        
        // Initialize URL session
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 10
        sessionConfig.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: sessionConfig)
        
        // Initialize API client
        apiClient = ApiClient(baseURL: config.apiURL, apiKey: apiKey, session: session)

        // Persist local feature flags
        runtimeConfig.setLocalSecureVoiceEnabled(options.enableSecureVoice)

        // Register device (best-effort; fail-open)
        let deviceId = deviceIdentity.getOrCreateDeviceId()
        apiClient.registerDevice(
            deviceId: deviceId,
            platform: "ios",
            deviceType: nil,
            osVersion: "\(ProcessInfo.processInfo.operatingSystemVersionString)",
            appVersion: nil,
            sdkVersion: nil,
            customerName: options.customerName,
            customerAccountNumber: options.customerAccountNumber
        ) { _ in
            // ignore
        }
        
        // Initialize database
        database = BrandingDatabase()
        
        // Initialize image cache
        imageCache = ImageCache()
        
        // Clean up old branding data periodically
        cleanupOldBranding()

        // Auto-sync every 30 minutes (best-effort; runs only while the app process is alive).
        startAutoSyncEvery30Minutes()

        // Best-effort: flush queued offline events on startup.
        flushPendingEvents()
        flushPendingTelemetry()
    }
    
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
        let startedAt = Date()
        apiClient.syncBranding(since: since) { [weak self] result in
            switch result {
            case .success(let response):
                // Store in local database
                if since == nil {
                    self?.database.replaceAllBranding(response.branding)
                } else {
                    self?.database.saveBranding(response.branding)
                }

                // Persist config (non-breaking) so call handling can gate assistance when capped/disabled.
                if let cfg = response.config {
                    self?.runtimeConfig.setBrandingEnabled(cfg.brandingEnabled ?? true)
                    if let voip = cfg.voipDialerEnabled {
                        self?.runtimeConfig.setServerSecureVoiceEnabled(voip)
                    }
                }
                
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
                completion(.failure(error))
            }
        }
    }

    private func startAutoSyncEvery30Minutes() {
        autoSyncTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        // Start a few seconds after init, then every 30 minutes.
        timer.schedule(deadline: .now() + 5, repeating: 30 * 60, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in
            self?.syncBranding(since: nil) { _ in
                // ignore
            }
        }
        autoSyncTimer = timer
        timer.resume()
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
            completion(.success(cached))
            return
        }
        
        // Fallback to API lookup
        apiClient.lookupBranding(phoneNumber: phoneNumber) { [weak self] result in
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
                    completion(.success(BrandingInfo(
                        phoneNumberE164: phoneNumber,
                        brandName: nil,
                        logoUrl: nil,
                        callReason: nil,
                        brandId: nil,
                        updatedAt: ""
                    )))
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
        completion: ((Result<BrandingEventResponse, Error>) -> Void)? = nil
    ) {
        apiClient.recordEvent(
            phoneNumberE164: phoneNumberE164,
            outcome: outcome,
            surface: surface,
            displayedAt: displayedAt
        ) { [weak self] result in
            switch result {
            case .success(let resp):
                // Keep local gate in sync with server caps if returned.
                if let enabled = resp.config?.brandingEnabled {
                    self?.runtimeConfig.setBrandingEnabled(enabled)
                }
                completion?(.success(resp))
            case .failure(let err):
                // Queue offline and return error to caller (best-effort).
                let iso = displayedAt ?? ISO8601DateFormatter().string(from: Date())
                self?.database.insertPendingEvent(
                    phoneNumberE164: phoneNumberE164,
                    outcome: outcome,
                    surface: surface,
                    displayedAt: iso
                )
                self?.database.prunePendingEvents(olderThanDays: 7)
                completion?(.failure(err))
            }
        }
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
                group.enter()
                self.apiClient.recordEvent(
                    phoneNumberE164: r.phoneNumberE164,
                    outcome: r.outcome,
                    surface: r.surface,
                    displayedAt: r.displayedAt
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
     * Clean up old branding data (older than retention period)
     */
    private func cleanupOldBranding() {
        let retentionDays: TimeInterval = 30 * 24 * 60 * 60
        let cutoffTime = Date().addingTimeInterval(-retentionDays)
        database.deleteOldBranding(before: cutoffTime)
        imageCache.cleanupOldImages()
    }
}

/**
 * SDK Configuration
 */
public struct SecureNodeConfig {
    public let apiURL: URL
    public let apiKey: String
    
    public init(apiURL: URL, apiKey: String = "") {
        self.apiURL = apiURL
        self.apiKey = apiKey
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
}

