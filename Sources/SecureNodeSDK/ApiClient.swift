import Foundation

/**
 * API client for SecureNode branding endpoints
 */
class ApiClient {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    
    init(baseURL: URL, apiKey: String, session: URLSession) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }
    
    /**
     * Sync branding data from API
     */
    func syncBranding(
        since: String?,
        completion: @escaping (Result<SyncResponse, Error>) -> Void
    ) {
        var urlComponents = URLComponents(url: baseURL.appendingPathComponent("mobile/branding/sync"), resolvingAgainstBaseURL: false)
        
        if let since = since {
            urlComponents?.queryItems = [URLQueryItem(name: "since", value: since)]
        }
        
        guard let url = urlComponents?.url else {
            completion(.failure(ApiError.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                completion(.failure(ApiError.invalidResponse))
                return
            }
            
            guard let data = data else {
                completion(.failure(ApiError.noData))
                return
            }
            
            do {
                let decoder = JSONDecoder()
                let response = try decoder.decode(SyncResponse.self, from: data)
                completion(.success(response))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
    
    /**
     * Lookup branding for a single phone number
     */
    func lookupBranding(
        phoneNumber: String,
        completion: @escaping (Result<BrandingInfo?, Error>) -> Void
    ) {
        var urlComponents = URLComponents(url: baseURL.appendingPathComponent("mobile/branding/lookup"), resolvingAgainstBaseURL: false)
        urlComponents?.queryItems = [URLQueryItem(name: "e164", value: phoneNumber)]
        
        guard let url = urlComponents?.url else {
            completion(.failure(ApiError.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                completion(.failure(ApiError.invalidResponse))
                return
            }
            
            guard let data = data else {
                completion(.success(nil))
                return
            }
            
            do {
                let decoder = JSONDecoder()
                let response = try decoder.decode(BrandingInfo.self, from: data)
                
                // Only return if brand name exists
                if response.brandName != nil {
                    completion(.success(response))
                } else {
                    completion(.success(nil))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
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
        // Prefer /mobile/*, fallback to /api/mobile/* for deployments that include /api prefix.
        let paths = ["mobile/branding/event", "api/mobile/branding/event"]
        recordEventTryPaths(
            paths: paths,
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

        let url = baseURL.appendingPathComponent(first)
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
}

/**
 * Branding information struct
 */
public struct BrandingInfo: Codable {
    public let phoneNumberE164: String
    public let brandName: String?
    public let logoUrl: String?
    public let callReason: String?
    public let updatedAt: String
    
    enum CodingKeys: String, CodingKey {
        case phoneNumberE164 = "phone_number_e164"
        case phoneNumberE164Alt = "e164"
        case brandName = "brand_name"
        case logoUrl = "logo_url"
        case callReason = "call_reason"
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

