import Foundation

/**
 * API client for SecureNode branding endpoints
 */
class ApiClient {
    private let baseRootURL: URL
    private let baseApiURL: URL
    private let apiKey: String
    private let session: URLSession
    private let debugLog: ((String) -> Void)?

    init(baseURL: URL, apiKey: String, session: URLSession, debugLog: ((String) -> Void)? = nil) {
        // Accept either:
        // - https://api.securenode.io        (root)
        // - https://api.securenode.io/api    (root with /api prefix)
        //
        // We normalize to a root base and always try both:
        // - /mobile/...
        // - /api/mobile/...
        let normalizedRoot: URL = {
            let trimmed = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if trimmed.hasSuffix("/api"), let url = URL(string: String(trimmed.dropLast(4))) {
                return url
            }
            return URL(string: trimmed) ?? baseURL
        }()

        self.baseRootURL = normalizedRoot
        self.baseApiURL = normalizedRoot.appendingPathComponent("api")
        self.apiKey = apiKey
        self.session = session
        self.debugLog = debugLog
    }

    private func urlCandidates(_ path: String) -> [URL] {
        // path example: "mobile/branding/sync"; try /api/ path first (OpenAPI defines /api/mobile/...).
        return [
            baseApiURL.appendingPathComponent(path),
            baseRootURL.appendingPathComponent(path),
        ]
    }

    private func runFirstOK<T>(
        urls: [URL],
        build: @escaping (URL) -> URLRequest,
        decode: @escaping (Data) throws -> T,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        guard let first = urls.first else {
            completion(.failure(ApiError.invalidURL))
            return
        }

        let request = build(first)

        session.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                let isCancelled = (error as? URLError)?.code == .cancelled
                if let self = self, !isCancelled, urls.count > 1 {
                    self.runFirstOK(urls: Array(urls.dropFirst()), build: build, decode: decode, completion: completion)
                    return
                }
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(ApiError.invalidResponse))
                return
            }

            if (httpResponse.statusCode == 404 || httpResponse.statusCode == 405), let self = self, urls.count > 1 {
                self.runFirstOK(urls: Array(urls.dropFirst()), build: build, decode: decode, completion: completion)
                return
            }

            if !(200...299).contains(httpResponse.statusCode) {
                let bodySnippet: String
                if let d = data, let s = String(data: d, encoding: .utf8) {
                    bodySnippet = String(s.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                } else {
                    bodySnippet = "(no body)"
                }
                let code = httpResponse.statusCode
                completion(.failure(ApiError.httpStatus(code, bodySnippet)))
                return
            }

            guard let data = data else {
                completion(.failure(ApiError.noData))
                return
            }

            do {
                let decoded = try decode(data)
                completion(.success(decoded))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
    
    /**
     * Sync branding data from API
     */
    func syncBranding(
        since: String?,
        deviceId: String?,
        completion: @escaping (Result<SyncResponse, Error>) -> Void
    ) {
        let urls = urlCandidates("mobile/branding/sync").map { base in
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            var items: [URLQueryItem] = []
            if let since = since {
                items.append(URLQueryItem(name: "since", value: since))
            }
            if let deviceId = deviceId, !deviceId.isEmpty {
                items.append(URLQueryItem(name: "device_id", value: deviceId))
            }
            comps?.queryItems = items.isEmpty ? nil : items
            return comps?.url ?? base
        }

        runFirstOK(
            urls: urls,
            build: { url in
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.setValue(self.apiKey, forHTTPHeaderField: "X-API-Key")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                return req
            },
            decode: { data in
                try JSONDecoder().decode(SyncResponse.self, from: data)
            },
            completion: completion
        )
    }

    /**
     * POST sync ack: notify server that sync was applied (OpenAPI BrandingSyncAckRequest).
     * Trigger: after successful GET sync.
     */
    func syncAck(
        lastSyncedAt: String,
        e164Numbers: [String]? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var body: [String: Any] = ["last_synced_at": lastSyncedAt]
        if let numbers = e164Numbers, !numbers.isEmpty { body["e164_numbers"] = numbers }
        runFirstOK(
            urls: urlCandidates("mobile/branding/sync"),
            build: { url in
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue(self.apiKey, forHTTPHeaderField: "X-API-Key")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                return req
            },
            decode: { _ in () },
            completion: completion
        )
    }

    /**
     * Best-effort: record a branding imprint (call branding activity).
     * Drives per-device activity sparklines in the portal.
     */
    func recordImprint(
        deviceId: String,
        phoneNumberE164: String,
        displayedAt: String? = nil,
        platform: String? = nil,
        osVersion: String? = nil,
        deviceModel: String? = nil,
        campaignId: String? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let urls = urlCandidates("mobile/branding/imprint")
        runFirstOK(
            urls: urls,
            build: { url in
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue(self.apiKey, forHTTPHeaderField: "X-API-Key")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")

                var body: [String: Any] = [
                    "phone_number_e164": phoneNumberE164,
                    "displayed_at": displayedAt ?? ISO8601DateFormatter().string(from: Date()),
                    "device_id": deviceId
                ]
                if let platform = platform, !platform.isEmpty {
                    body["platform"] = platform
                }
                if let osVersion = osVersion, !osVersion.isEmpty {
                    body["os_version"] = osVersion
                }
                if let deviceModel = deviceModel, !deviceModel.isEmpty {
                    body["device_model"] = deviceModel
                }
                if let campaignId = campaignId, !campaignId.isEmpty {
                    body["campaign_id"] = campaignId
                }
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                return req
            },
            decode: { _ in () },
            completion: completion
        )
    }
    
    /**
     * Lookup branding for a single phone number
     */
    func lookupBranding(
        phoneNumber: String,
        deviceId: String?,
        completion: @escaping (Result<BrandingInfo?, Error>) -> Void
    ) {
        let urls = urlCandidates("mobile/branding/lookup").compactMap { base in
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            var items: [URLQueryItem] = [
                URLQueryItem(name: "e164", value: phoneNumber),
                URLQueryItem(name: "format", value: "public")
            ]
            if let deviceId = deviceId, !deviceId.isEmpty {
                items.append(URLQueryItem(name: "device_id", value: deviceId))
            }
            comps?.queryItems = items
            return comps?.url
        }

        runFirstOK(
            urls: urls,
            build: { url in
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.setValue(self.apiKey, forHTTPHeaderField: "X-API-Key")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                return req
            },
            decode: { data in
                // Empty body means "no match" for some deployments
                if data.isEmpty { return nil }
                let decoded = try JSONDecoder().decode(BrandingInfo.self, from: data)
                return decoded.brandName != nil ? decoded : nil
            },
            completion: completion
        )
    }

    /**
     * Record a ring-time event for billing/audit.
     * Required fields: phone_number_e164, outcome, displayed_at; include event_key and device_id where applicable.
     * Outcomes: displayed, no_match, disabled, error, call_seen, call_returned, missed.
     */
    func recordEvent(
        phoneNumberE164: String,
        outcome: String,
        surface: String?,
        displayedAt: String? = nil,
        deviceId: String? = nil,
        eventKey: String? = nil,
        meta: [String: Any]? = nil,
        completion: @escaping (Result<BrandingEventResponse, Error>) -> Void
    ) {
        let displayedAtValue = displayedAt ?? ISO8601DateFormatter().string(from: Date())
        var body: [String: Any] = [
            "phone_number_e164": phoneNumberE164,
            "outcome": outcome,
            "displayed_at": displayedAtValue
        ]
        if let v = surface, !v.isEmpty { body["surface"] = v }
        if let v = deviceId, !v.isEmpty { body["device_id"] = v }
        if let v = eventKey, !v.isEmpty { body["event_key"] = v }
        if let m = meta, !m.isEmpty { body["meta"] = m }

        runFirstOK(
            urls: urlCandidates("mobile/branding/event"),
            build: { url in
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue(self.apiKey, forHTTPHeaderField: "X-API-Key")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                return req
            },
            decode: { data in try JSONDecoder().decode(BrandingEventResponse.self, from: data) },
            completion: completion
        )
    }

    func registerDevice(
        deviceId: String,
        platform: String,
        deviceType: String?,
        osVersion: String?,
        appVersion: String?,
        sdkVersion: String?,
        customerName: String?,
        customerAccountNumber: String?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var body: [String: Any] = ["device_id": deviceId, "platform": platform]
        if let v = deviceType, !v.isEmpty { body["device_type"] = v }
        if let v = osVersion, !v.isEmpty { body["os_version"] = v }
        if let v = appVersion, !v.isEmpty { body["app_version"] = v }
        if let v = sdkVersion, !v.isEmpty { body["sdk_version"] = v }
        if let v = customerName, !v.isEmpty { body["customer_name"] = v }
        if let v = customerAccountNumber, !v.isEmpty { body["customer_account_number"] = v }

        runFirstOK(
            urls: urlCandidates("mobile/device/register"),
            build: { url in
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue(self.apiKey, forHTTPHeaderField: "X-API-Key")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                return req
            },
            decode: { _ in () },
            completion: completion
        )
    }

    /**
     * Best-effort telemetry/log ingestion (non-blocking).
     * POST /api/mobile/device/log.
     */
    func sendDeviceLog(
        deviceId: String,
        level: String,
        message: String,
        meta: [String: Any]?,
        occurredAt: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var body: [String: Any] = [
            "device_id": deviceId,
            "level": level,
            "message": String(message.prefix(1800)),
            "occurred_at": occurredAt
        ]
        if let meta = meta { body["meta"] = meta }

        runFirstOK(
            urls: urlCandidates("mobile/device/log"),
            build: { url in
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue(self.apiKey, forHTTPHeaderField: "X-API-Key")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                return req
            },
            decode: { _ in () },
            completion: completion
        )
    }

    /**
     * Presence heartbeat: signals this device is active so the system can show it as "present".
     * Uses /mobile/device/presence with fallback to /api/mobile/device/presence.
     * Call periodically (e.g. every 5 min) so the API knows the client is alive.
     */
    func sendPresenceHeartbeat(
        deviceId: String,
        observedAt: String,
        platform: String? = nil,
        osVersion: String? = nil,
        lastSyncedAt: String? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var body: [String: Any] = [
            "device_id": deviceId,
            "observed_at": observedAt
        ]
        if let platform = platform, !platform.isEmpty { body["platform"] = platform }
        if let osVersion = osVersion, !osVersion.isEmpty { body["os_version"] = osVersion }
        if let lastSyncedAt = lastSyncedAt, !lastSyncedAt.isEmpty { body["last_synced_at"] = lastSyncedAt }
        let bodyData = try? JSONSerialization.data(withJSONObject: body)

        runFirstOK(
            urls: urlCandidates("mobile/device/presence"),
            build: { url in
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue(self.apiKey, forHTTPHeaderField: "X-API-Key")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = bodyData
                return req
            },
            decode: { _ in () },
            completion: completion
        )
    }

    /**
     * Authoritative, idempotent device state update.
     * Uses /mobile/device/update with fallback to /api/mobile/device/update.
     * Portal "active devices" uses last_seen from this endpoint.
     */
    func updateDevice(
        deviceId: String,
        platform: String,
        osVersion: String?,
        appVersion: String?,
        sdkVersion: String?,
        capabilities: [String: Any]?,
        lastSeen: String?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var body: [String: Any] = [
            "device_id": deviceId,
            "platform": platform
        ]
        if let v = osVersion, !v.isEmpty { body["os_version"] = v }
        if let v = appVersion, !v.isEmpty { body["app_version"] = v }
        if let v = sdkVersion, !v.isEmpty { body["sdk_version"] = v }
        if let v = lastSeen, !v.isEmpty { body["last_seen"] = v }
        if let cap = capabilities { body["capabilities"] = cap }

        runFirstOK(
            urls: urlCandidates("mobile/device/update"),
            build: { url in
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue(self.apiKey, forHTTPHeaderField: "X-API-Key")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                return req
            },
            decode: { _ in () },
            completion: completion
        )
    }

    /**
     * POST /api/mobile/debug/upload.
     * Trigger only when sync config has debug_request_upload and debug_allow_export enabled.
     */
    func uploadDebug(
        deviceId: String,
        nonce: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let body: [String: Any] = ["device_id": deviceId, "nonce": nonce]
        runFirstOK(
            urls: urlCandidates("mobile/debug/upload"),
            build: { url in
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue(self.apiKey, forHTTPHeaderField: "X-API-Key")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                return req
            },
            decode: { _ in () },
            completion: completion
        )
    }
}

/**
 * Branding information struct
 */
public struct BrandingInfo: Codable {
    public let phoneNumberE164: String
    public let brandName: String?
    public let logoUrl: String?
    public let callReason: String?
    public let brandId: String?
    public let updatedAt: String
    
    enum CodingKeys: String, CodingKey {
        case phoneNumberE164 = "phone_number_e164"
        case phoneNumberE164Alt = "e164"
        case brandName = "brand_name"
        case logoUrl = "logo_url"
        case callReason = "call_reason"
        case brandId = "brand_id"
        case updatedAt = "updated_at"
    }

    public init(phoneNumberE164: String, brandName: String?, logoUrl: String?, callReason: String?, brandId: String?, updatedAt: String) {
        self.phoneNumberE164 = phoneNumberE164
        self.brandName = brandName
        self.logoUrl = logoUrl
        self.callReason = callReason
        self.brandId = brandId
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phoneNumberE164 =
            (try? c.decode(String.self, forKey: .phoneNumberE164)) ??
            (try? c.decode(String.self, forKey: .phoneNumberE164Alt)) ??
            ""
        brandName = try? c.decodeIfPresent(String.self, forKey: .brandName)
        logoUrl = try? c.decodeIfPresent(String.self, forKey: .logoUrl)
        callReason = try? c.decodeIfPresent(String.self, forKey: .callReason)
        brandId = try? c.decodeIfPresent(String.self, forKey: .brandId)
        updatedAt = (try? c.decode(String.self, forKey: .updatedAt)) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(phoneNumberE164, forKey: .phoneNumberE164)
        try c.encodeIfPresent(brandName, forKey: .brandName)
        try c.encodeIfPresent(logoUrl, forKey: .logoUrl)
        try c.encodeIfPresent(callReason, forKey: .callReason)
        try c.encodeIfPresent(brandId, forKey: .brandId)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

/**
 * Sync response struct
 */
public struct SyncResponse: Codable {
    public let branding: [BrandingInfo]
    public let syncedAt: String
    public let config: SyncConfig?
    
    enum CodingKeys: String, CodingKey {
        case branding
        case syncedAt = "synced_at"
        case config
    }
}

public struct SyncConfig: Codable {
    public let voipDialerEnabled: Bool?
    public let mode: String?
    public let brandingEnabled: Bool?
    /// Debug upload gate (OpenAPI DebugUiPolicy). POST /api/mobile/debug/upload only when request_upload && allow_export.
    public let debugUi: DebugUiPolicy?

    enum CodingKeys: String, CodingKey {
        case voipDialerEnabled = "voip_dialer_enabled"
        case mode
        case brandingEnabled = "branding_enabled"
        case debugUi = "debug_ui"
    }
}

public struct DebugUiPolicy: Codable {
    public let enabled: Bool
    public let requestUpload: Bool
    public let expiresAt: String?
    public let allowExport: Bool

    enum CodingKeys: String, CodingKey {
        case enabled
        case requestUpload = "request_upload"
        case expiresAt = "expires_at"
        case allowExport = "allow_export"
    }
}

public struct BrandingEventResponse: Codable {
    public let success: Bool
    public let eventId: String?
    public let counted: Bool?
    public let outcome: String?
    public let reason: String?
    public let imprintId: String?
    public let displayedAt: String?
    public let config: SyncConfig?

    enum CodingKeys: String, CodingKey {
        case success
        case eventId = "event_id"
        case counted
        case outcome
        case reason
        case imprintId = "imprint_id"
        case displayedAt = "displayed_at"
        case config
    }
}

/**
 * API errors
 */
enum ApiError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case noData
    /// HTTP status outside 2xx (e.g. 403 Forbidden). Associated: statusCode, optional response body snippet.
    case httpStatus(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL"
        case .invalidResponse: return "Invalid API response"
        case .noData: return "No data from API"
        case .httpStatus(403, _): return "403 Forbidden — check API key and permissions"
        case .httpStatus(let code, let body):
            if let body = body, !body.isEmpty { return "API error \(code): \(body)" }
            return "API error \(code)"
        }
    }
}

