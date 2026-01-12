import Foundation
import CallKit
import SecureNodeSDK

/// SecureNode Call Directory Extension sample.
///
/// This target lives inside the CUSTOMER app project (as a Call Directory Extension).
/// It reads the latest validated snapshot from the App Group container and loads labels.
final class CallDirectoryHandler: CXCallDirectoryProvider {
    /// IMPORTANT: Customer-owned App Group ID (must match the host app + SDK configuration).
    /// Example: "group.com.customer.app.securenode"
    private let appGroupId: String = "<APP_GROUP_ID>"

    override func beginRequest(with context: CXCallDirectoryExtensionContext) {
        // For simplicity, we always do a full reload.
        // iOS may call incrementally; you can optimize later using diffs if needed.
        context.removeAllIdentificationEntries()

        do {
            let entries = try SecureNodeCallDirectorySnapshotReader.loadEntries(appGroupId: appGroupId)

            // Entries are already sorted ascending by the SDK snapshot writer,
            // but we still enforce monotonic ordering.
            var last: Int64 = -1
            for e in entries {
                let digits = e.digits
                guard let num = Int64(digits) else { continue }
                guard num > last else { continue }
                last = num

                context.addIdentificationEntry(withNextSequentialPhoneNumber: num, label: e.label)
            }

            context.completeRequest()
        } catch {
            context.cancelRequest(withError: error)
        }
    }
}

