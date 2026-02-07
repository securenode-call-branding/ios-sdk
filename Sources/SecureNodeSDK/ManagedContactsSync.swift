import Foundation
import Contacts
import UIKit
import CryptoKit

final class ManagedContactsSync: @unchecked Sendable {
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
    /// ContactStore must not be used on the main thread; run all store operations here.
    private let contactQueue = DispatchQueue(label: "com.securenode.contacts", qos: .userInitiated)

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
        case .limited: return "limited"
        @unknown default: return "unknown"
        }
    }

    /// Call early (e.g. on app launch) so the Contacts permission prompt and Settings row appear even before the first sync. No-op if already determined.
    static func requestPermissionIfNeeded() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return }
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { _, _ in }
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
            let contactId = existing?.contactId ?? ""
            let contactIdentifier = contactId.isEmpty ? nil : contactId

            let (updatedId, photoApplied, photoFailed, registryRemove) = try await upsertManagedContact(
                existingContactIdentifier: contactIdentifier,
                group: g
            )

            if registryRemove {
                reg.entries.removeValue(forKey: g.groupId)
            } else if let updatedId = updatedId {
                upserted += 1
                if photoApplied { photosApplied += 1 }
                if photoFailed { photoFailures += 1 }
                reg.entries[g.groupId] = ManagedContactsRegistry.Entry(
                    contactId: updatedId,
                    lastSynced: ISO8601DateFormatter().string(from: Date())
                )
            }
        }

        var deleted = 0
        let toDelete = reg.entries.keys.filter { !desiredGroupIds.contains($0) }
        for gid in toDelete {
            if let entry = reg.entries[gid] {
                try await deleteContactIfExists(identifier: entry.contactId)
                reg.entries.removeValue(forKey: gid)
                deleted += 1
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
    ) async throws -> (contactId: String?, photoApplied: Bool, photoFailed: Bool, registryRemove: Bool) {
        let urlValue = "securenode://managed?group=\(group.groupId)&v=1"

        var photoApplied = false
        var photoFailed = false
        var imageData: Data?
        for attempt in 1...2 {
            do {
                imageData = try await downloadAndProcessImage(urlString: group.logoUrl)
                if imageData != nil { break }
            } catch {
                if attempt == 2 { photoFailed = true }
                else { try? await Task.sleep(nanoseconds: 500_000_000) }
            }
        }
        if imageData != nil { photoApplied = true }
        else if !photoFailed { photoFailed = true }

        if let id = existingContactIdentifier, !id.isEmpty {
            try? await deleteContactIfExists(identifier: id)
        }

        let mutable = CNMutableContact()
        mutable.givenName = group.brandName
        mutable.familyName = ""
        mutable.organizationName = group.brandName
        mutable.phoneNumbers = group.e164s.map {
            CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: $0))
        }
        let logoURL = CNLabeledValue(label: "Logo", value: group.logoUrl as NSString)
        let markerURL = CNLabeledValue(label: "SecureNode", value: urlValue as NSString)
        mutable.urlAddresses = [logoURL, markerURL]

        let addRequest = CNSaveRequest()
        addRequest.add(mutable, toContainerWithIdentifier: nil)

        let imageDataForQueue = imageData
        let urlValueForQueue = urlValue

        struct AddAndMaybeUpdateResult {
            let effectiveId: String?
            let recordGone: Bool
            let imageApplied: Bool
        }

        let result: AddAndMaybeUpdateResult = try await runOnContactQueue {
            do {
                try self.store.execute(addRequest)
            } catch {
                let ns = error as NSError
                if ns.domain == "CNErrorDomain", ns.code == 200 {
                    return AddAndMaybeUpdateResult(effectiveId: nil, recordGone: true, imageApplied: false)
                }
                throw error
            }

            var foundId: String?
            let keysForFind: [CNKeyDescriptor] = [
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactUrlAddressesKey as CNKeyDescriptor
            ]
            let request = CNContactFetchRequest(keysToFetch: keysForFind)
            try? self.store.enumerateContacts(with: request) { contact, _ in
                if foundId != nil { return }
                for labeled in contact.urlAddresses {
                    if labeled.value as String == urlValueForQueue {
                        foundId = contact.identifier
                        return
                    }
                }
            }
            guard let effectiveId = foundId else {
                return AddAndMaybeUpdateResult(effectiveId: nil, recordGone: false, imageApplied: false)
            }

            var imageApplied = false
            if let data = imageDataForQueue {
                let updateKeys: [CNKeyDescriptor] = [
                    CNContactGivenNameKey as CNKeyDescriptor,
                    CNContactFamilyNameKey as CNKeyDescriptor,
                    CNContactOrganizationNameKey as CNKeyDescriptor,
                    CNContactPhoneNumbersKey as CNKeyDescriptor,
                    CNContactUrlAddressesKey as CNKeyDescriptor,
                    CNContactImageDataKey as CNKeyDescriptor,
                    CNContactIdentifierKey as CNKeyDescriptor
                ]
                guard let contact = try? self.store.unifiedContact(withIdentifier: effectiveId, keysToFetch: updateKeys) else {
                    return AddAndMaybeUpdateResult(effectiveId: nil, recordGone: true, imageApplied: false)
                }
                let toUpdate = contact.mutableCopy() as! CNMutableContact
                toUpdate.imageData = data
                let updateRequest = CNSaveRequest()
                updateRequest.update(toUpdate)
                do {
                    try self.store.execute(updateRequest)
                    imageApplied = true
                } catch {
                    let ns = error as NSError
                    if ns.domain == "CNErrorDomain", ns.code == 200 {
                        return AddAndMaybeUpdateResult(effectiveId: nil, recordGone: true, imageApplied: false)
                    }
                }
            }
            return AddAndMaybeUpdateResult(effectiveId: effectiveId, recordGone: false, imageApplied: imageApplied)
        }

        if result.recordGone {
            return (nil, photoApplied, photoFailed, true)
        }
        if !result.imageApplied && imageData != nil {
            photoFailed = true
        }
        return (result.effectiveId, photoApplied, photoFailed, false)
    }

    private func runOnContactQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            contactQueue.async { [weak self] in
                guard self != nil else {
                    cont.resume(throwing: NSError(domain: "ManagedContactsSync", code: -1, userInfo: [NSLocalizedDescriptionKey: "unavailable"]))
                    return
                }
                do {
                    let result = try work()
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func findContactIdentifier(byURL urlValue: String) async -> String? {
        try? await runOnContactQueue { () -> String? in
            let keys: [CNKeyDescriptor] = [
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactUrlAddressesKey as CNKeyDescriptor
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var found: String?
            try? self.store.enumerateContacts(with: request) { contact, _ in
                if found != nil { return }
                for labeled in contact.urlAddresses {
                    if labeled.value as String == urlValue {
                        found = contact.identifier
                        return
                    }
                }
            }
            return found
        }
    }

    private func deleteContactIfExists(identifier: String) async throws {
        guard !identifier.isEmpty else { return }
        try await runOnContactQueue {
            let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor]
            guard let contact = try? self.store.unifiedContact(withIdentifier: identifier, keysToFetch: keys) else { return }
            let mutable = contact.mutableCopy() as! CNMutableContact
            let req = CNSaveRequest()
            req.delete(mutable)
            try self.store.execute(req)
        }
    }

    private func downloadAndProcessImage(urlString: String) async throws -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        let data = try await URLSession(configuration: config).data(from: url).0
        guard let img = UIImage(data: data) else { return nil }

        // Small JPEG so Contacts persists it; 128x128 and cap ~50KB.
        let target = CGSize(width: 128, height: 128)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let rendered = renderer.image { _ in
            img.draw(in: CGRect(origin: .zero, size: target))
        }
        for q in [0.8, 0.6, 0.5] as [CGFloat] {
            guard let jpg = rendered.jpegData(compressionQuality: q), jpg.count <= 60_000 else { continue }
            return jpg
        }
        return rendered.jpegData(compressionQuality: 0.4)
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

