import Foundation
import Contacts
import UIKit
import CryptoKit

final class ManagedContactsSync {
    struct Result {
        let permission: String
        let upserted: Int
        let deleted: Int
        let photosApplied: Int
        let photoFailures: Int
    }

    private let appGroupId: String
    private let store = CNContactStore()
    private let registry: ManagedContactsRegistry

    init(appGroupId: String) {
        self.appGroupId = appGroupId
        self.registry = ManagedContactsRegistry(appGroupId: appGroupId)
    }

    static func contactsPermissionString() -> String {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }

    func syncManagedContacts(
        branding: [BrandingInfo],
        maxProfiles: Int,
        maxPhoneNumbersPerContact: Int
    ) async throws -> Result {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            _ = try await requestAccess()
        }

        let status2 = CNContactStore.authorizationStatus(for: .contacts)
        let perm = Self.contactsPermissionString()
        guard status2 == .authorized else {
            return Result(permission: perm, upserted: 0, deleted: 0, photosApplied: 0, photoFailures: 0)
        }

        // Only build managed contacts for entries that have an image (photo is non-negotiable attempt).
        // If logo is missing, rely on Call Directory label only.
        let candidates = branding.filter { ($0.logoUrl ?? "").isEmpty == false && ($0.brandName ?? "").isEmpty == false }

        let groups = Self.buildGroups(
            branding: candidates,
            maxProfiles: maxProfiles,
            maxPhoneNumbersPerContact: maxPhoneNumbersPerContact
        )

        var desiredGroupIds = Set<String>()
        var upserted = 0
        var photosApplied = 0
        var photoFailures = 0

        var reg = try registry.load()

        for g in groups {
            desiredGroupIds.insert(g.groupId)

            let existing = reg.entries[g.groupId]
            let contactId = existing?.contactId
            let contactIdentifier = contactId ?? ""

            let (updatedId, photoApplied, photoFailed) = try upsertManagedContact(
                existingContactIdentifier: contactIdentifier.isEmpty ? nil : contactIdentifier,
                group: g
            )

            if let updatedId = updatedId {
                upserted += 1
                if photoApplied { photosApplied += 1 }
                if photoFailed { photoFailures += 1 }
                reg.entries[g.groupId] = ManagedContactsRegistry.Entry(
                    contactId: updatedId,
                    lastSynced: ISO8601DateFormatter().string(from: Date())
                )
            }
        }

        // Cleanup registry entries that are no longer desired.
        var deleted = 0
        let toDelete = reg.entries.keys.filter { !desiredGroupIds.contains($0) }
        if !toDelete.isEmpty {
            for gid in toDelete {
                if let entry = reg.entries[gid] {
                    try deleteContactIfExists(identifier: entry.contactId)
                    reg.entries.removeValue(forKey: gid)
                    deleted += 1
                }
            }
        }

        try registry.save(reg)

        return Result(
            permission: perm,
            upserted: upserted,
            deleted: deleted,
            photosApplied: photosApplied,
            photoFailures: photoFailures
        )
    }

    // MARK: - Grouping

    private struct Group {
        let groupId: String
        let brandName: String
        let logoUrl: String
        let e164s: [String]
    }

    private static func buildGroups(
        branding: [BrandingInfo],
        maxProfiles: Int,
        maxPhoneNumbersPerContact: Int
    ) -> [Group] {
        var byBrand = [String: (logoUrl: String, e164s: [String])]()
        for b in branding {
            let name = (b.brandName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let logo = (b.logoUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let e164 = b.phoneNumberE164.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !logo.isEmpty, !e164.isEmpty else { continue }

            var current = byBrand[name] ?? (logoUrl: logo, e164s: [])
            // Keep first logo url we saw for the brand (stable enough for v1).
            if current.logoUrl.isEmpty { current.logoUrl = logo }
            current.e164s.append(e164)
            byBrand[name] = current
        }

        var out: [Group] = []
        out.reserveCapacity(min(maxProfiles, byBrand.count))

        // Stable ordering by brand name to keep grouping deterministic.
        let brands = byBrand.keys.sorted()
        for brandName in brands {
            guard let payload = byBrand[brandName] else { continue }
            let uniqueE164s = Array(Set(payload.e164s)).sorted()
            let chunks = stride(from: 0, to: uniqueE164s.count, by: maxPhoneNumbersPerContact).map {
                Array(uniqueE164s[$0..<min($0 + maxPhoneNumbersPerContact, uniqueE164s.count)])
            }

            for (idx, chunk) in chunks.enumerated() {
                if out.count >= maxProfiles { return out }
                let gid = stableGroupId(brandName: brandName, chunkIndex: idx)
                out.append(Group(groupId: gid, brandName: brandName, logoUrl: payload.logoUrl, e164s: chunk))
            }
        }

        return out
    }

    private static func stableGroupId(brandName: String, chunkIndex: Int) -> String {
        let input = "brand:\(brandName)|chunk:\(chunkIndex)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Contacts ops

    private func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { cont in
            store.requestAccess(for: .contacts) { granted, err in
                if let err = err { cont.resume(throwing: err); return }
                cont.resume(returning: granted)
            }
        }
    }

    private func upsertManagedContact(
        existingContactIdentifier: String?,
        group: Group
    ) throws -> (contactId: String?, photoApplied: Bool, photoFailed: Bool) {
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactImageDataKey as CNKeyDescriptor
        ]

        let mutable: CNMutableContact
        if let id = existingContactIdentifier, !id.isEmpty {
            if let existing = try? store.unifiedContact(withIdentifier: id, keysToFetch: keys) {
                mutable = existing.mutableCopy() as! CNMutableContact
            } else {
                mutable = CNMutableContact()
            }
        } else {
            mutable = CNMutableContact()
        }

        // Basic identity
        mutable.givenName = group.brandName
        mutable.familyName = ""

        // Phone numbers (as-is; Call Directory handles labels reliably)
        mutable.phoneNumbers = group.e164s.map {
            CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: $0))
        }

        // Marker URL field (less visible than notes; per spec)
        let urlValue = "securenode://managed?group=\(group.groupId)&v=1"
        let labeledURL = CNLabeledValue(label: "SecureNode", value: urlValue as NSString)
        mutable.urlAddresses = [labeledURL]

        // Photo attempt
        var photoApplied = false
        var photoFailed = false
        do {
            if let data = try downloadAndProcessImage(urlString: group.logoUrl) {
                mutable.imageData = data
                photoApplied = true
            } else {
                photoFailed = true
            }
        } catch {
            photoFailed = true
        }

        let save = CNSaveRequest()
        if (mutable.identifier).isEmpty {
            save.add(mutable, toContainerWithIdentifier: nil)
        } else {
            save.update(mutable)
        }
        try store.execute(save)

        return (mutable.identifier, photoApplied, photoFailed)
    }

    private func deleteContactIfExists(identifier: String) throws {
        guard !identifier.isEmpty else { return }
        let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor]
        guard let contact = try? store.unifiedContact(withIdentifier: identifier, keysToFetch: keys) else { return }
        let mutable = contact.mutableCopy() as! CNMutableContact
        let req = CNSaveRequest()
        req.delete(mutable)
        try store.execute(req)
    }

    private func downloadAndProcessImage(urlString: String) throws -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        let data = try Data(contentsOf: url)
        guard let img = UIImage(data: data) else { return nil }

        // Resize to a safe square to avoid oversized contact images.
        let target = CGSize(width: 256, height: 256)
        let rendered = UIGraphicsImageRenderer(size: target).image { _ in
            img.draw(in: CGRect(origin: .zero, size: target))
        }

        // JPEG is compact; PNG if JPEG fails.
        if let jpg = rendered.jpegData(compressionQuality: 0.85) { return jpg }
        return rendered.pngData()
    }
}

final class ManagedContactsRegistry {
    struct Entry: Codable {
        let contactId: String
        let lastSynced: String
    }

    struct Registry: Codable {
        var entries: [String: Entry] // groupId -> entry
    }

    private let fm = FileManager.default
    private let appGroupId: String

    init(appGroupId: String) {
        self.appGroupId = appGroupId
    }

    func load() throws -> Registry {
        guard let base = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            throw SecureNodeError.invalidAppGroup
        }
        let url = base.appendingPathComponent("managed_contacts_registry.json")
        guard fm.fileExists(atPath: url.path) else { return Registry(entries: [:]) }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Registry.self, from: data)
    }

    func save(_ reg: Registry) throws {
        guard let base = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            throw SecureNodeError.invalidAppGroup
        }
        let url = base.appendingPathComponent("managed_contacts_registry.json")
        let data = try JSONEncoder().encode(reg)
        try data.write(to: url, options: [.atomic])
    }
}

