import Foundation

public struct CallEventPayload: Encodable {
    public let eventKey: String
    public let deviceId: String
    public let phoneNumberE164: String
    public let brandingApplied: Bool?
    public let brandingProfileId: String?
    public let meta: [String: String]?

    enum CodingKeys: String, CodingKey {
        case eventKey = "event_key"
        case deviceId = "device_id"
        case phoneNumberE164 = "phone_number_e164"
        case brandingApplied = "branding_applied"
        case brandingProfileId = "branding_profile_id"
        case meta
    }
}
