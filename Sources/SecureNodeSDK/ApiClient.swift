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
        case phoneNumberE164 = "e164"
        case brandName = "brand_name"
        case logoUrl = "logo_url"
        case callReason = "call_reason"
        case updatedAt = "updated_at"
    }
}

/**
 * Sync response struct
 */
public struct SyncResponse: Codable {
    public let branding: [BrandingInfo]
    public let syncedAt: String
    
    enum CodingKeys: String, CodingKey {
        case branding
        case syncedAt = "synced_at"
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

