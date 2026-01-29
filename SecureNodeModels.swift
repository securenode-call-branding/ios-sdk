import Foundation

public struct BrandingInfo: Codable {
    public let phoneNumberE164: String
    public let brandName: String?
    public let logoURL: URL?
    public let callReason: String?
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case phoneNumberE164 = "phone_number_e164"
        case brandName = "brand_name"
        case logoURL = "logo_url"
        case callReason = "call_reason"
        case updatedAt = "updated_at"
    }
}

public struct SyncResponse: Codable {
    public let branding: [BrandingInfo]
    public let syncedAt: String

    enum CodingKeys: String, CodingKey {
        case branding
        case syncedAt = "synced_at"
    }
}

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
