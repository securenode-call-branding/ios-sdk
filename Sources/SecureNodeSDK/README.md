//
//  SecureNode.swift
//  SecureNode
//
//  Created by SecureNode Team on 2026-02-01.
//

import Foundation
import Contacts

public struct SecureNodeHeadlessConfig {
    public let apiURL: URL
    public let apiKey: String
    public let appGroupId: String?
    public let callDirectoryExtensionBundleId: String?
    public let maxManagedContactProfiles: Int
    public let maxPhoneNumbersPerContact: Int
    public let debugLog: Bool
    
    public init(
        apiURL: URL,
        apiKey: String,
        appGroupId: String? = nil,
        callDirectoryExtensionBundleId: String? = nil,
        maxManagedContactProfiles: Int = 24,
        maxPhoneNumbersPerContact: Int = 5,
        debugLog: Bool = false
    ) {
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.appGroupId = appGroupId
        self.callDirectoryExtensionBundleId = callDirectoryExtensionBundleId
        self.maxManagedContactProfiles = maxManagedContactProfiles
        self.maxPhoneNumbersPerContact = maxPhoneNumbersPerContact
        self.debugLog = debugLog
    }
}

public enum SecureNodeError: Error {
    case notConfigured
    case permissionDenied
    case reloadFailed(Error)
    case syncFailed(Error)
}

public final class SecureNode {
    private static var config: SecureNodeHeadlessConfig?
    private static let queue = DispatchQueue(label: "com.securenode.sdk.sync.queue")
    private static var isConfigured: Bool {
        config != nil
    }
    
    /// Configure the SecureNode Headless facade with the provided configuration.
    /// Must be called once at app startup before any other API calls.
    public static func configure(_ config: SecureNodeHeadlessConfig) {
        self.config = config
        if config.debugLog {
            print("[SecureNode] Configured with apiURL: \(config.apiURL), appGroupId: \(config.appGroupId ?? "nil")")
        }
    }
    
    /// Perform a full sync operation: branding data, managed contacts, and presence heartbeat.
    /// Throws upon failure.
    @discardableResult
    public static func sync() async throws -> String {
        guard let config = config else {
            throw SecureNodeError.notConfigured
        }
        if config.debugLog {
            print("[SecureNode] Starting sync")
        }
        
        // Step 1: Sync branding data from API
        let brandingAck = try await syncBranding(config: config)
        
        // Step 2: Sync managed contacts if appGroupId is set
        if let appGroupId = config.appGroupId {
            try await syncManagedContacts(config: config, appGroupId: appGroupId)
        }
        
        // Step 3: Send presence heartbeat (fire and forget)
        sendPresenceHeartbeat(config: config)
        
        // Step 4: Write call directory snapshot and trigger reload if needed
        if let extensionBundleId = config.callDirectoryExtensionBundleId,
           let appGroupId = config.appGroupId {
            try await writeCallDirectorySnapshotAndReload(
                appGroupId: appGroupId,
                extensionBundleId: extensionBundleId,
                debugLog: config.debugLog
            )
        }
        
        if config.debugLog {
            print("[SecureNode] sync ack: \(brandingAck)")
        }
        return brandingAck
    }
    
    /// Reload the Call Directory extension if needed.
    /// Throws if reload fails.
    public static func reloadCallDirectoryIfNeeded() async throws {
        guard let config = config,
              let appGroupId = config.appGroupId,
              let extensionBundleId = config.callDirectoryExtensionBundleId else {
            throw SecureNodeError.notConfigured
        }
        
        if config.debugLog {
            print("[SecureNode] Reloading Call Directory Extension if needed")
        }
        
        try await writeCallDirectorySnapshotAndReload(
            appGroupId: appGroupId,
            extensionBundleId: extensionBundleId,
            debugLog: config.debugLog
        )
    }
}

// MARK: - Private Implementation

private extension SecureNode {
    static func syncBranding(config: SecureNodeHeadlessConfig) async throws -> String {
        // Example simplified branding sync, replace with real API calls
        // For demonstration: pretend fetching branding JSON from API endpoint
        
        guard var components = URLComponents(url: config.apiURL, resolvingAgainstBaseURL: false) else {
            throw SecureNodeError.syncFailed(NSError(domain: "SecureNode", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid API URL"]))
        }
        components.path = "/branding/sync"
        guard let url = components.url else {
            throw SecureNodeError.syncFailed(NSError(domain: "SecureNode", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid Sync URL"]))
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpMethod = "GET"
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
            throw SecureNodeError.syncFailed(NSError(domain: "SecureNode", code: 3, userInfo: [NSLocalizedDescriptionKey: "API returned error status"]))
        }
        
        // Parse response (assume JSON with { "status": "ok" } or similar)
        if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
           let status = json["status"] as? String {
            if config.debugLog {
                print("[SecureNode] Branding sync status: \(status)")
            }
            return status
        } else {
            throw SecureNodeError.syncFailed(NSError(domain: "SecureNode", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid branding sync response"]))
        }
    }
    
    static func syncManagedContacts(config: SecureNodeHeadlessConfig, appGroupId: String) async throws {
        // Check Contacts authorization
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .notDetermined:
            // Request access
            let granted = try await requestContactsAccess()
            if !granted {
                throw SecureNodeError.permissionDenied
            }
        case .restricted, .denied:
            throw SecureNodeError.permissionDenied
        case .authorized, .limited:
            break
        @unknown default:
            throw SecureNodeError.permissionDenied
        }
        
        // Fetch managed brand data from API (this is a placeholder)
        // Group phone numbers by brand, up to maxManagedContactProfiles and maxPhoneNumbersPerContact
        
        // For demonstration, let's create dummy contacts data
        let brands: [(name: String, phoneNumbers: [String])] = [
            ("Brand Alpha", ["+12345678901", "+12345678902"]),
            ("Brand Beta", ["+19876543210"])
        ]
        
        // Limit according to config
        let limitedBrands = brands.prefix(config.maxManagedContactProfiles)
        
        // Prepare contacts for insertion
        try await queue.async {
            let store = CNContactStore()
            let saveRequest = CNSaveRequest()
            
            // Clear previously managed contacts (identify by container or a specific label)
            // For simplicity, here we remove contacts with note containing "SecureNode Managed"
            let predicate = CNContact.predicateForContactsInContainer(withIdentifier: store.defaultContainerIdentifier())
            let keysToFetch = [CNContactGivenNameKey, CNContactNoteKey] as [CNKeyDescriptor]
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
            for contact in contacts {
                if contact.note.contains("SecureNode Managed") {
                    let mutableContact = contact.mutableCopy() as! CNMutableContact
                    saveRequest.delete(mutableContact)
                }
            }
            
            // Add new managed contacts
            for brand in limitedBrands {
                let contact = CNMutableContact()
                contact.givenName = brand.name
                contact.note = "SecureNode Managed"
                var labeledValues: [CNLabeledValue<CNPhoneNumber>] = []
                for phone in brand.phoneNumbers.prefix(config.maxPhoneNumbersPerContact) {
                    labeledValues.append(CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phone)))
                }
                contact.phoneNumbers = labeledValues
                saveRequest.add(contact, toContainerWithIdentifier: nil)
            }
            
            try store.execute(saveRequest)
            
            if config.debugLog {
                print("[SecureNode] Managed contacts synced: \(limitedBrands.count) brands")
            }
        }
    }
    
    static func requestContactsAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            CNContactStore().requestAccess(for: .contacts) { granted, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }
    
    static func sendPresenceHeartbeat(config: SecureNodeHeadlessConfig) {
        // Fire and forget presence heartbeat reporting to API
        // For demonstration, simple async task without await
        
        Task.detached {
            guard var components = URLComponents(url: config.apiURL, resolvingAgainstBaseURL: false) else {
                if config.debugLog {
                    print("[SecureNode] Presence heartbeat: invalid apiURL")
                }
                return
            }
            components.path = "/presence/heartbeat"
            guard let url = components.url else {
                if config.debugLog {
                    print("[SecureNode] Presence heartbeat: invalid URL")
                }
                return
            }
            
            var request = URLRequest(url: url)
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            request.httpMethod = "POST"
            
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) {
                    if config.debugLog {
                        print("[SecureNode] Presence heartbeat sent")
                    }
                } else {
                    if config.debugLog {
                        print("[SecureNode] Presence heartbeat failed")
                    }
                }
            } catch {
                if config.debugLog {
                    print("[SecureNode] Presence heartbeat error: \(error)")
                }
            }
        }
    }
    
    static func writeCallDirectorySnapshotAndReload(appGroupId: String, extensionBundleId: String, debugLog: Bool) async throws {
        // Write branding data snapshot and trigger Call Directory reload
        
        // Sample snapshot data: list of phone numbers and labels
        let snapshot: [[String: String]] = [
            ["number": "+12345678901", "label": "Brand Alpha"],
            ["number": "+19876543210", "label": "Brand Beta"]
        ]
        
        // Serialize snapshot to plist or JSON in app group container
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            throw SecureNodeError.syncFailed(NSError(domain: "SecureNode", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid App Group ID"]))
        }
        
        let snapshotURL = containerURL.appendingPathComponent("CallDirectorySnapshot.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted])
            try data.write(to: snapshotURL, options: .atomic)
            if debugLog {
                print("[SecureNode] Call Directory snapshot written to \(snapshotURL.path)")
            }
        } catch {
            throw SecureNodeError.syncFailed(error)
        }
        
        // Trigger reload of Call Directory extension using CXCallDirectoryManager
        try await withCheckedThrowingContinuation { continuation in
            let managerClass = NSClassFromString("CallKit.CXCallDirectoryManager")
            guard let managerType = managerClass as? NSObject.Type else {
                continuation.resume(throwing: SecureNodeError.reloadFailed(NSError(domain: "SecureNode", code: 6, userInfo: [NSLocalizedDescriptionKey: "CallDirectoryManager class missing"])))
                return
            }
            let manager = managerType.init()
            let selector = NSSelectorFromString("reloadExtensionWithIdentifier:completionHandler:")
            guard manager.responds(to: selector) else {
                continuation.resume(throwing: SecureNodeError.reloadFailed(NSError(domain: "SecureNode", code: 7, userInfo: [NSLocalizedDescriptionKey: "reloadExtensionWithIdentifier:completionHandler: selector missing"])))
                return
            }
            
            typealias CompletionHandler = (Error?) -> Void
            let block: @convention(block) (NSError?) -> Void = { error in
                if let error = error {
                    if debugLog {
                        print("[SecureNode] Call Directory reload failed: \(error.localizedDescription)")
                    }
                    continuation.resume(throwing: SecureNodeError.reloadFailed(error))
                } else {
                    if debugLog {
                        print("[SecureNode] Call Directory reload succeeded")
                    }
                    continuation.resume(returning: ())
                }
            }
            
            let imp = manager.method(for: selector)
            typealias Func = @convention(c) (AnyObject, Selector, String, @escaping CompletionHandler) -> Void
            let function = unsafeBitCast(imp, to: Func.self)
            function(manager, selector, extensionBundleId, block)
        }
    }
}
