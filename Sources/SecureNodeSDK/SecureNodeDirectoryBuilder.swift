import Foundation

enum SecureNodeDirectoryBuilder {
    static func buildSnapshotEntries(from branding: [BrandingInfo], maxActiveNumbers: Int) -> [SecureNodeSnapshotEntry] {
        // active branding entries should already be filtered server-side, but fail-safe here.
        var entries: [SecureNodeSnapshotEntry] = []
        entries.reserveCapacity(min(branding.count, maxActiveNumbers))

        for b in branding {
            let e164 = b.phoneNumberE164.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !e164.isEmpty else { continue }
            let digits = e164.filter(\.isNumber)
            guard let _ = Int64(digits) else { continue }

            let name = (b.brandName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            // Include call_reason so the OS has name/reason for display and to help bypass unknown/spam filtering.
            let reason = (b.callReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let label = reason.isEmpty ? name : "\(name) (\(reason))"

            entries.append(SecureNodeSnapshotEntry(e164: e164, digits: digits, label: label))
            if entries.count >= maxActiveNumbers { break }
        }

        // Call Directory requires ascending order. Sort by numeric digits then e164 as tie-breaker.
        entries.sort { a, b in
            if a.digits == b.digits { return a.e164 < b.e164 }
            // Lex compare works for same-length digits; for safety compare length then lex.
            if a.digits.count != b.digits.count { return a.digits.count < b.digits.count }
            return a.digits < b.digits
        }

        return entries
    }
}

public struct SecureNodeSnapshotEntry: Codable {
    public let e164: String
    public let digits: String
    public let label: String

    public init(e164: String, digits: String, label: String) {
        self.e164 = e164
        self.digits = digits
        self.label = label
    }
}

