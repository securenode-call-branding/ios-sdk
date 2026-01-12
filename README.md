# SecureNode iOS SDK

iOS SDK for SecureNode Call Identity branding integration.

This SDK is **headless** (no UI). On iOS, production-grade caller ID uses **both**:
- **Call Directory Extension** for OS-managed caller ID **labels**
- **Contacts sync** for managed contact **photos**

## Features

- ✅ **Call Directory snapshots (App Group)** - Atomic, validated snapshots for the extension to read
- ✅ **Call Directory reload policy** - Host app calls `SecureNode.reloadCallDirectoryIfNeeded()`
- ✅ **Managed Contacts sync** - SecureNode-managed contacts with photos (permission-gated)
- ✅ **Secure API Key Management** - Keychain storage for API credentials
- ✅ **Incremental Sync** - Efficient bandwidth usage with delta updates
- ✅ **Error Handling** - Graceful fallbacks and error recovery
- ✅ **Thread-Safe** - Safe for use in multi-threaded call handling
- 🧩 **Secure Voice / SIP (future add-on)** - Ship VoIP dialer capability now, enable later via flags (SIP engine not bundled yet)

## Installation

### Swift Package Manager

Add the following to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/securenode-call-branding/ios-sdk.git", from: "1.0.0")
]
```

Or add via Xcode:
1. File → Add Packages...
2. Enter: `https://github.com/securenode-call-branding/ios-sdk.git`
3. Select version: `1.0.0`

### CocoaPods

```ruby
pod 'SecureNodeSDK', '~> 1.0.0'
```

## Quick Start

### 1. Configure the headless SDK

```swift
import SecureNodeSDK

SecureNode.configure(.init(
  apiURL: URL(string: "https://verify.securenode.io")!,
  apiKey: "your-api-key-here", // Portal → API Access
  appGroupId: "group.com.customer.app.securenode",
  callDirectoryExtensionBundleId: "com.customer.app.CallDirectoryExtension"
))
```

### 2. Sync + reload Call Directory (host app)

```swift
let report = try await SecureNode.sync()
_ = try await SecureNode.reloadCallDirectoryIfNeeded()
```

### 3. Call Directory Extension (required for OS labels)

The extension is a **separate target** inside the customer app project.
Use the reference handler in:

- `ios-sdk/Examples/SecureNodeCallDirectoryExtension/CallDirectoryHandler.swift`

The extension reads the App Group snapshot and loads labels into the OS.

### 3a. Host app refresh pattern (recommended)

See:

- `ios-sdk/Examples/SecureNodeHostAppSnippet/README.md`

### 4. Contacts permission (for photos)

Contacts sync is attempted when permission is **granted or not yet determined**.
If permission is denied, the SDK continues without Contacts and caller ID labels still work via Call Directory.

## Usage

### Manual lookup (optional)

```swift
// Use your existing app’s call handling to decide when to do lookups.
// The OS caller ID labels come from Call Directory snapshots.
```

## API Reference

### SecureNode (Headless)
- `configure(_:)`
- `sync()`
- `reloadCallDirectoryIfNeeded()`
- `health()`

### BrandingInfo

Struct containing branding information:

```swift
struct BrandingInfo {
    let phoneNumberE164: String
    let brandName: String?
    let logoUrl: String?
    let callReason: String?
    let updatedAt: String
}
```

## Security

- API keys are stored securely using iOS Keychain
- All network requests use HTTPS
- Directory snapshots are validated (hash + schema) before being activated

## Requirements

- **iOS**: 13.0+
- **Swift**: 5.5+
- **Xcode**: 14.0+

## License

Apache-2.0

## Support

- Documentation: [https://verify.securenode.io/sdk](https://verify.securenode.io/sdk)
- Issues: [GitHub Issues](https://github.com/securenode-call-branding/ios-sdk/issues)

