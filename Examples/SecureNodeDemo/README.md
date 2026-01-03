## SecureNode iOS Demo (for dev trial downloads)

This repo is the **Swift Package** (`ios-sdk/`) only. iOS app builds (`.app` / `.ipa`) require **macOS + Xcode**.

### Create the demo app (Xcode)
1. Open Xcode → **File → New → Project** → iOS → **App**
2. Name: `SecureNodeDemo`
3. Minimum iOS: 15+ (recommended)
4. In the project:
   - **File → Add Packages…**
   - Add **Local package** and select this folder: `ios-sdk/`
5. Add these keys to your app’s `Info.plist` as needed for networking + call surfaces.

### Minimal install + sync
In your `App` startup:

```swift
import SecureNodeSDK

// Example:
let sdk = SecureNodeSDK(apiUrl: "https://verify.securenode.io", apiKey: "<YOUR_API_KEY>")
sdk.syncBranding()
```

### Build an IPA for dev downloads
Use Xcode **Archive** (Product → Archive) and export for:
- Ad Hoc / TestFlight (recommended)
- Enterprise (if you have it)


