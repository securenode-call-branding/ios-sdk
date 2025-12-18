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
    apiURL: URL(string: "https://portal.securenode.io/api")!,
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

The SDK provides a ready-to-use `CallKitManager` that handles incoming calls automatically:

```swift
import CallKit
import SecureNodeSDK

class CallKitManager: NSObject {
    private let provider: CXProvider
    private let secureNode: SecureNodeSDK
    
    override init() {
        let configuration = CXProviderConfiguration(localizedName: "YourApp")
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber]
        
        provider = CXProvider(configuration: configuration)
        secureNode = SecureNodeSDK(config: config)
        
        super.init()
        provider.setDelegate(self, queue: nil)
    }
    
    func handleIncomingCall(uuid: UUID, phoneNumber: String) {
        secureNode.getBranding(for: phoneNumber) { [weak self] result in
            guard let self = self else { return }
            
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .phoneNumber, value: phoneNumber)
            
            switch result {
            case .success(let branding):
                update.localizedCallerName = branding.brandName
                // Apply logo and call reason
            case .failure:
                update.localizedCallerName = phoneNumber
            }
            
            self.provider.reportNewIncomingCall(with: uuid, update: update) { error in
                if let error = error {
                    print("Failed to report call: \(error)")
                }
            }
        }
    }
}
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

- Documentation: [https://portal.securenode.io/sdk](https://portal.securenode.io/sdk)
- Issues: [GitHub Issues](https://github.com/SecureNode-Call-Identidy-SDK/apple-ios-sdk/issues)

