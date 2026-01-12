import Foundation

final class CallDirectoryReloadPolicy {
    private let defaults: UserDefaults

    private let keyLastSyncAt = "securenode_cd_last_sync_at"
    private let keyLastReloadAt = "securenode_cd_last_reload_at"
    private let keyFailures = "securenode_cd_reload_failures"
    private let keyBackoffUntil = "securenode_cd_backoff_until"

    // Conservative defaults; can be tuned later.
    private let minReloadIntervalSeconds: TimeInterval = 5 * 60
    private let baseBackoffSeconds: TimeInterval = 30
    private let maxBackoffSeconds: TimeInterval = 30 * 60

    init(appGroupId: String) {
        self.defaults = UserDefaults(suiteName: appGroupId) ?? .standard
    }

    func recordLastSyncNow() {
        defaults.set(Date().timeIntervalSince1970, forKey: keyLastSyncAt)
    }

    func lastSyncAtIso() -> String? { iso(key: keyLastSyncAt) }
    func lastReloadAtIso() -> String? { iso(key: keyLastReloadAt) }

    func shouldReloadNow() -> (allowed: Bool, nextAllowedAt: String?) {
        let now = Date().timeIntervalSince1970

        let backoffUntil = defaults.double(forKey: keyBackoffUntil)
        if backoffUntil > now {
            return (false, ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: backoffUntil)))
        }

        let last = defaults.double(forKey: keyLastReloadAt)
        if last > 0, now - last < minReloadIntervalSeconds {
            let next = last + minReloadIntervalSeconds
            return (false, ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: next)))
        }

        return (true, nil)
    }

    func recordReloadSuccessNow() {
        defaults.set(Date().timeIntervalSince1970, forKey: keyLastReloadAt)
        defaults.set(0, forKey: keyFailures)
        defaults.set(0, forKey: keyBackoffUntil)
    }

    func recordReloadFailureNow() {
        let now = Date().timeIntervalSince1970
        defaults.set(now, forKey: keyLastReloadAt)

        let failures = defaults.integer(forKey: keyFailures) + 1
        defaults.set(failures, forKey: keyFailures)

        let backoff = min(maxBackoffSeconds, baseBackoffSeconds * pow(2.0, Double(max(0, failures - 1))))
        defaults.set(now + backoff, forKey: keyBackoffUntil)
    }

    func nextAllowedAtIso() -> String? {
        let until = defaults.double(forKey: keyBackoffUntil)
        guard until > 0 else { return nil }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: until))
    }

    private func iso(key: String) -> String? {
        let t = defaults.double(forKey: key)
        guard t > 0 else { return nil }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: t))
    }
}

