import Foundation

/**
 * API client for SecureNode branding endpoints
 */
class ApiClient {
    private let baseRootURL: URL
    private let baseApiURL: URL
    private let apiKey: String
    private let session: URLSession
    
    init(baseURL: URL, apiKey: String, session: URLSession) {
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
    }

    private func urlCandidates(_ path: String) -> [URL] {
        // path example: "mobile/branding/sync"
        return [
            baseRootURL.appendingPathComponent(path),
            baseApiURL.appendingPathComponent(path),
        ]
    }

    private func runFirstOK<T>(
        urls: [URL],
        build: (URL) -> URLRequest,
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
                if let self = self, urls.count > 1 {
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

            // If this endpoint isn't mounted here, try the next base.
            if httpResponse.statusCode == 404, let self = self, urls.count > 1 {
                self.runFirstOK(urls: Array(urls.dropFirst()), build: build, decode: decode, completion: completion)
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                completion(.failure(ApiError.invalidResponse))
                return
            }

            guard let data = data else {
                completion(.failure(ApiError.noData))
                return
            }

            do {
                completion(.success(try decode(data)))
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
     * Best-effort: record a branding imprint (call branding activity).
     * Drives per-device activity sparklines in the portal.
     */
    func recordImprint(
        deviceId: String,
        phoneNumberE164: String,
        displayedAt: String? = nil,
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

                let body: [String: Any] = [
                    "phone_number_e164": phoneNumberE164,
                    "displayed_at": displayedAt ?? ISO8601DateFormatter().string(from: Date()),
                    "device_id": deviceId
                ]
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
        completion: @escaping (Result<BrandingInfo?, Error>) -> Void
    ) {
        let urls = urlCandidates("mobile/branding/lookup").compactMap { base in
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            comps?.queryItems = [URLQueryItem(name: "e164", value: phoneNumber)]
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
     *
     * This endpoint is the authoritative event stream (outcome=assisted is billable when allowed).
     */
    func recordEvent(
        phoneNumberE164: String,
        outcome: String,
        surface: String?,
        displayedAt: String? = nil,
        completion: @escaping (Result<BrandingEventResponse, Error>) -> Void
    ) {
        // Try both base mounts:
        // - {root}/mobile/...
        // - {root}/api/mobile/...
        recordEventTryPaths(
            paths: urlCandidates("mobile/branding/event").map { $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) },
            phoneNumberE164: phoneNumberE164,
            outcome: outcome,
            surface: surface,
            displayedAt: displayedAt,
            completion: completion
        )
    }

    private func recordEventTryPaths(
        paths: [String],
        phoneNumberE164: String,
        outcome: String,
        surface: String?,
        displayedAt: String?,
        completion: @escaping (Result<BrandingEventResponse, Error>) -> Void
    ) {
        guard let first = paths.first else {
            completion(.failure(ApiError.invalidURL))
            return
        }

        let url = URL(string: "\(baseRootURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(first)") ?? baseRootURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "phone_number_e164": phoneNumberE164,
            "outcome": outcome,
            "surface": surface as Any,
            "displayed_at": displayedAt ?? ISO8601DateFormatter().string(from: Date())
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        session.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                // Try next path on network/transport failures too (best-effort).
                if let self = self, paths.count > 1 {
                    self.recordEventTryPaths(
                        paths: Array(paths.dropFirst()),
                        phoneNumberE164: phoneNumberE164,
                        outcome: outcome,
                        surface: surface,
                        displayedAt: displayedAt,
                        completion: completion
                    )
                    return
                }
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(ApiError.invalidResponse))
                return
            }

            // If endpoint doesn't exist on this path, try the fallback path.
            if httpResponse.statusCode == 404, let self = self, paths.count > 1 {
                self.recordEventTryPaths(
                    paths: Array(paths.dropFirst()),
                    phoneNumberE164: phoneNumberE164,
                    outcome: outcome,
                    surface: surface,
                    displayedAt: displayedAt,
                    completion: completion
                )
                return
            }

            guard (200...299).contains(httpResponse.statusCode), let data = data else {
                completion(.failure(ApiError.invalidResponse))
                return
            }

            do {
                let decoder = JSONDecoder()
                let response = try decoder.decode(BrandingEventResponse.self, from: data)
                completion(.success(response))
            } catch {
                completion(.failure(error))
            }
        }.resume()
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
        let urls = urlCandidates("mobile/device/register")
        runFirstOK(
            urls: urls,
            build: { url in
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue(self.apiKey, forHTTPHeaderField: "X-API-Key")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let body: [String: Any] = [
                    "device_id": deviceId,
                    "platform": platform,
                    "device_type": deviceType as Any,
                    "os_version": osVersion as Any,
                    "app_version": appVersion as Any,
                    "sdk_version": sdkVersion as Any,
                    "customer_name": customerName as Any,
                    "customer_account_number": customerAccountNumber as Any
                ]
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                return req
            },
            decode: { _ in () },
            completion: completion
        )
    }

    /**
     * Best-effort telemetry/log ingestion.
     * Uses /mobile/device/log with fallback to /api/mobile/device/log.
     */
    func sendDeviceLog(
        deviceId: String,
        level: String,
        message: String,
        meta: [String: Any]?,
        occurredAt: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        sendDeviceLogTryPaths(
            paths: urlCandidates("mobile/device/log").map { $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) },
            deviceId: deviceId,
            level: level,
            message: message,
            meta: meta,
            occurredAt: occurredAt,
            completion: completion
        )
    }

    private func sendDeviceLogTryPaths(
        paths: [String],
        deviceId: String,
        level: String,
        message: String,
        meta: [String: Any]?,
        occurredAt: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let first = paths.first else {
            completion(.failure(ApiError.invalidURL))
            return
        }

        let url = URL(string: "\(baseRootURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(first)") ?? baseRootURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "device_id": deviceId,
            "level": level,
            "message": String(message.prefix(1800)),
            "occurred_at": occurredAt
        ]
        if let meta = meta {
            body["meta"] = meta
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        session.dataTask(with: request) { [weak self] _, response, error in
            if let error = error {
                if let self = self, paths.count > 1 {
                    self.sendDeviceLogTryPaths(
                        paths: Array(paths.dropFirst()),
                        deviceId: deviceId,
                        level: level,
                        message: message,
                        meta: meta,
                        occurredAt: occurredAt,
                        completion: completion
                    )
                    return
                }
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(ApiError.invalidResponse))
                return
            }

            if httpResponse.statusCode == 404, let self = self, paths.count > 1 {
                self.sendDeviceLogTryPaths(
                    paths: Array(paths.dropFirst()),
                    deviceId: deviceId,
                    level: level,
                    message: message,
                    meta: meta,
                    occurredAt: occurredAt,
                    completion: completion
                )
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                completion(.failure(ApiError.invalidResponse))
                return
            }

            completion(.success(()))
        }.resume()
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

    enum CodingKeys: String, CodingKey {
        case voipDialerEnabled = "voip_dialer_enabled"
        case mode
        case brandingEnabled = "branding_enabled"
    }
}

public struct BrandingEventResponse: Codable {
    public let success: Bool
    public let counted: Bool?
    public let outcome: String?
    public let reason: String?
    public let imprintId: String?
    public let displayedAt: String?
    public let config: SyncConfig?

    enum CodingKeys: String, CodingKey {
        case success
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
enum ApiError: Error {
    case invalidURL
    case invalidResponse
    case noData
}

