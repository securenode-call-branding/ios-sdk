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
    private let apiClient: ApiClient
    private let database: BrandingDatabase
    private let keychainManager: KeychainManager
    private let imageCache: ImageCache
    private let session: URLSession
    
    /**
     * Initialize the SDK
     */
    public init(config: SecureNodeConfig) {
        self.config = config
        
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
        
        // Initialize database
        database = BrandingDatabase()
        
        // Initialize image cache
        imageCache = ImageCache()
        
        // Clean up old branding data periodically
        cleanupOldBranding()
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
        apiClient.syncBranding(since: since) { [weak self] result in
            switch result {
            case .success(let response):
                // Store in local database
                self?.database.saveBranding(response.branding)
                
                // Pre-cache images in background
                response.branding.forEach { branding in
                    if let logoUrl = branding.logoUrl {
                        self?.imageCache.loadImageAsync(from: logoUrl) { _ in }
                    }
                }
                
                completion(.success(response))
            case .failure(let error):
                completion(.failure(error))
            }
        }
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
        // First try local database
        if let cached = database.getBranding(for: phoneNumber) {
            completion(.success(cached))
            return
        }
        
        // Fallback to API lookup
        apiClient.lookupBranding(phoneNumber: phoneNumber) { [weak self] result in
            switch result {
            case .success(let branding):
                if let branding = branding, branding.brandName != nil {
                    // Cache for next time
                    self?.database.saveBranding([branding])
                }
                completion(result)
            case .failure(let error):
                completion(.failure(error))
            }
        }
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

