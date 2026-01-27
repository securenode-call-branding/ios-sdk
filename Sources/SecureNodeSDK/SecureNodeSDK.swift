import Foundation
import CallKit
import UIKit
#if canImport(CryptoKit)
import CryptoKit
#endif

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
    private let trustDelegate: URLSessionDelegate?
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
        
        // Initialize URL session (trust system roots + SecureNode client CA).
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 10
        sessionConfig.timeoutIntervalForResource = 10
        let delegate = SecureNodeTrustDelegate()
        self.trustDelegate = delegate.isEnabled ? delegate : nil
        self.session = URLSession(configuration: sessionConfig, delegate: self.trustDelegate, delegateQueue: nil)
        
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
                // Keep local gate in sync with server caps if returned.
                if let enabled = resp.config?.brandingEnabled {
                    self?.runtimeConfig.setBrandingEnabled(enabled)
                }
                completion?(.success(resp))
            case .failure(let err):
                // Queue offline and return error to caller (best-effort).
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
    public let apiURL: URL
    public let apiKey: String
    public let campaignId: String?
    
    public init(apiURL: URL, apiKey: String = "", campaignId: String? = nil) {
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.campaignId = campaignId
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

