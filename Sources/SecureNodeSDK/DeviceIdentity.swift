import Foundation

final class DeviceIdentity {
    private let defaults = UserDefaults.standard
    private let key = "securenode_device_id"

    func getOrCreateDeviceId() -> String {
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }
}


