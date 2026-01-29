import Foundation

/// Feature flags that are safe to ship "off" and later enable without changing integration code.
///
/// IMPORTANT:
/// - These are LOCAL flags (client app decision).
/// - The server may also gate features (e.g. `voip_dialer_enabled`). Both must be enabled.
public struct SecureNodeOptions {
    public let enableSecureVoice: Bool
    public let customerName: String?
    public let customerAccountNumber: String?
    public let sip: SecureNodeSipConfig?
    /// Optional: called when SDK has API result lines to show (e.g. in a debug UI). Called on main thread.
    public let debugLog: ((String) -> Void)?

    public init(enableSecureVoice: Bool = false, customerName: String? = nil, customerAccountNumber: String? = nil, sip: SecureNodeSipConfig? = nil, debugLog: ((String) -> Void)? = nil) {
        self.enableSecureVoice = enableSecureVoice
        self.customerName = customerName
        self.customerAccountNumber = customerAccountNumber
        self.sip = sip
        self.debugLog = debugLog
    }
}

/// Placeholder SIP config (future upgrade path).
///
/// We intentionally do NOT bundle a SIP stack yet; this keeps the SDK lightweight and avoids licensing issues.
/// When we add Secure Voice/SIP, this config becomes the stable contract.
public struct SecureNodeSipConfig {
    public let server: String
    public let username: String?
    public let password: String?
    public let displayName: String?

    public init(server: String, username: String? = nil, password: String? = nil, displayName: String? = nil) {
        self.server = server
        self.username = username
        self.password = password
        self.displayName = displayName
    }
}


