import Foundation

/// Secure Voice (VoIP / SIP) upgrade path.
///
/// This is intentionally a thin façade today:
/// - Clients can ship it in their release, disabled by default.
/// - Later we can add a SIP engine implementation without changing the public API.
public enum SecureVoice {
    /// Returns true only when:
    /// - local flag is enabled in `SecureNodeOptions`
    /// - server flag `voip_dialer_enabled` is enabled
    public static func isEnabled(_ sdk: SecureNodeSDK) -> Bool {
        return sdk.isSecureVoiceEnabled()
    }

    /// Placeholder start hook (future).
    public static func start(_ sdk: SecureNodeSDK) {
        guard sdk.isSecureVoiceEnabled() else { return }
        // Future: initialize SIP engine + CallKit provider/dialer UI wiring.
    }
}


