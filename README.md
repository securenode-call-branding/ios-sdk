# SecureNode iOS SDK

iOS SDK for SecureNode Call Identity branding integration. Provides native CallKit integration for displaying branded caller information during incoming calls.

## Features

- ✅ **Native CallKit Integration** - Seamless iOS call interception
- ✅ **Local Database Caching** - SQLite database for instant branding lookups
- ✅ **Image Caching** - Automatic logo/image caching for offline support
- ✅ **Secure API Key Management** - Keychain storage for API credentials
- ✅ **Incremental Sync** - Efficient bandwidth usage with delta updates
- ✅ **Error Handling** - Graceful fallbacks and error recovery
- ✅ **Thread-Safe** - Safe for use in multi-threaded call handling

## Installation

### Swift Package Manager

Add the following to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/SecureNode-Call-Identidy-SDK/apple-ios-sdk.git", from: "1.0.0")
]
```

Or add via Xcode:
1. File → Add Packages...
2. Enter: `https://github.com/SecureNode-Call-Identidy-SDK/apple-ios-sdk.git`
3. Select version: `1.0.0`

### CocoaPods

```ruby
pod 'SecureNodeSDK', '~> 1.0.0'
```

## Quick Start

### 1. Initialize the SDK

```swift
import SecureNodeSDK

let config = SecureNodeConfig(
    apiURL: URL(string: "https://api.securenode.io")!,
    apiKey: "your-api-key-here" // Get from Portal → Settings → API Keys
)

let secureNode = SecureNodeSDK(config: config)
```

### 2. Enable VoIP Background Mode

Add to your `Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>voip</string>
</array>
```

### 3. Request CallKit Permissions

```swift
import CallKit

let provider = CXProvider(configuration: CXProviderConfiguration(localizedName: "YourApp"))
// Permissions are requested automatically when reporting calls
```

### 4. Sync Branding Data

```swift
// Initial sync
secureNode.syncBranding { result in
    switch result {
    case .success(let response):
        // Branding data cached locally
        print("Synced \(response.branding.count) branding records")
    case .failure(let error):
        // Handle error
        print("Sync failed: \(error)")
    }
}

// Incremental sync (periodically)
secureNode.syncBranding(since: lastSyncTimestamp) { result in
    // Only updates since last sync
}
```

## Usage

### CallKit Integration

Use the SDK’s one-call helper to apply branding + emit the **billable assisted event** automatically:

```swift
import CallKit
import SecureNodeSDK

let provider = CXProvider(configuration: CXProviderConfiguration(localizedName: "YourApp"))
provider.setDelegate(self, queue: nil)

// When your app receives an incoming VoIP call event:
secureNode.assistIncomingCall(uuid: uuid, phoneNumber: e164, provider: provider)
```

### Manual Branding Lookup

```swift
secureNode.getBranding(for: "+1234567890") { result in
    switch result {
    case .success(let branding):
        // Use branding.brandName, branding.logoUrl, branding.callReason
    case .failure(let error):
        // Handle error
    }
}
```

## API Reference

### SecureNodeSDK

Main SDK class for branding operations.

#### Methods

- `syncBranding(since: String?, completion: @escaping (Result<SyncResponse, Error>) -> Void)` - Sync branding data
- `getBranding(for phoneNumber: String, completion: @escaping (Result<BrandingInfo, Error>) -> Void)` - Lookup single number
- `assistIncomingCall(uuid: UUID, phoneNumber: String, provider: CXProvider, completion: ((Error?) -> Void)?)` - Apply branding + billable assisted event
- `recordAssistedEvent(phoneNumberE164: String, surface: String, displayedAt: String?, completion: ((Result<BrandingEventResponse, Error>) -> Void)?)` - Billable assisted event

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
- Local database is encrypted
- No sensitive data in logs

## Requirements

- **iOS**: 13.0+
- **Swift**: 5.5+
- **Xcode**: 14.0+

## License

GPL-3.0

## Support

- Documentation: [https://verify.securenode.io/sdk](https://verify.securenode.io/sdk)
- Issues: [GitHub Issues](https://github.com/SecureNode-Call-Identidy-SDK/apple-ios-sdk/issues)

