import Foundation
import CallKit

/// SecureNode Call Directory Extension — reads snapshot from App Group and provides labels for incoming calls.
/// SDK types (SecureNodeCallDirectorySnapshotReader) are compiled into this target.
final class CallDirectoryHandler: CXCallDirectoryProvider {
    private let appGroupId: String = "group.SecureNodeKit.SecureNode"

    override func beginRequest(with context: CXCallDirectoryExtensionContext) {
        defer { context.completeRequest() }
        let entries: [SecureNodeSnapshotEntry]
        do {
            entries = try SecureNodeCallDirectorySnapshotReader.loadEntries(appGroupId: appGroupId)
        } catch {
            // No snapshot yet or app group issue; complete with no entries so iOS keeps the extension enabled.
            return
        }
        guard !entries.isEmpty else { return }
        context.removeAllIdentificationEntries()
        var last: Int64 = -1
        for e in entries {
            let digits = e.digits
            guard let num = Int64(digits), num > last else { continue }
            last = num
            context.addIdentificationEntry(withNextSequentialPhoneNumber: num, label: e.label)
        }
    }
}
