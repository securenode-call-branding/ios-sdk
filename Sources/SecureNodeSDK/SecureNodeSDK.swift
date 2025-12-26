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
    private let runtimeConfig = RuntimeConfigStore()
    
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

                // Persist config (non-breaking) so call handling can gate assistance when capped/disabled.
                if let cfg = response.config {
                    self?.runtimeConfig.setBrandingEnabled(cfg.brandingEnabled ?? true)
                }
                
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
            case .success(let brandingOpt):
                if let branding = brandingOpt, branding.brandName != nil {
                    // Cache for next time
                    self?.database.saveBranding([branding])
                    completion(.success(branding))
                } else {
                    completion(.success(BrandingInfo(
                        phoneNumberE164: phoneNumber,
                        brandName: nil,
                        logoUrl: nil,
                        callReason: nil,
                        updatedAt: ""
                    )))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /**
     * Record a billing/audit event for an incoming call when SecureNode assisted the display.
     *
     * We keep it simple: send outcome="assisted". Server decides whether it's counted (caps/ownership).
     */
    public func recordAssistedEvent(
        phoneNumberE164: String,
        surface: String = "callkit",
        displayedAt: String? = nil,
        completion: ((Result<BrandingEventResponse, Error>) -> Void)? = nil
    ) {
        apiClient.recordEvent(
            phoneNumberE164: phoneNumberE164,
            outcome: "assisted",
            surface: surface,
            displayedAt: displayedAt
        ) { result in
            // Keep local gate in sync with server caps if returned.
            if case .success(let resp) = result, let enabled = resp.config?.brandingEnabled {
                self.runtimeConfig.setBrandingEnabled(enabled)
            }
            completion?(result)
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
                    self.recordAssistedEvent(phoneNumberE164: phoneNumber, surface: "callkit", completion: nil)
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

    func isBrandingEnabled() -> Bool {
        // Default allow until server tells us otherwise.
        if defaults.object(forKey: keyBrandingEnabled) == nil { return true }
        return defaults.bool(forKey: keyBrandingEnabled)
    }

    func setBrandingEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: keyBrandingEnabled)
    }
}

