## SecureNode Call Directory Extension (Sample)

This folder contains a **reference** `CXCallDirectoryProvider` implementation that reads SecureNode’s
latest validated directory snapshot from an **App Group** container.

### What this gives you
- **OS-managed caller ID labels** via Call Directory
- No network calls in the extension
- Snapshot reads are validated/rollback-safe (writer is in the SDK)

### How to use (in the customer app project)
1. In Xcode: **File → New → Target… → Call Directory Extension**
2. Add the SecureNode iOS SDK (SPM) to both:
   - Host app target
   - Call Directory Extension target
3. Enable **App Groups** for BOTH targets and pick a **customer-owned** group, e.g.:
   - `group.com.customer.app.securenode`
4. Copy `CallDirectoryHandler.swift` into the extension target and set:
   - `appGroupId` to your App Group id
5. In the host app, after `await SecureNode.sync()`:
   - call `await SecureNode.reloadCallDirectoryIfNeeded()`

### Notes
- Call Directory supports **labels only** (no images).
- Images are handled via **Contacts sync** (host app process) when permission is granted.

