## SecureNode Host App Integration (Snippet)

This is a minimal, **headless** host-app pattern showing when to call:
- `SecureNode.sync()`
- `SecureNode.reloadCallDirectoryIfNeeded()`

### 1) App startup (foreground)

```swift
import SecureNodeSDK

@main
struct MyApp: App {
  init() {
    SecureNode.configure(.init(
      apiURL: URL(string: "https://verify.securenode.io")!,
      apiKey: "<YOUR_API_KEY>",
      appGroupId: "group.com.customer.app.securenode",
      callDirectoryExtensionBundleId: "com.customer.app.CallDirectoryExtension"
    ))
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .task {
          // Initial boot sync (best-effort)
          try? await SecureNode.sync()
          try? await SecureNode.reloadCallDirectoryIfNeeded()
        }
    }
  }
}
```

### 2) Periodic refresh (recommended)

Your app should re-sync periodically (foreground sessions, background refresh if enabled).
Call reload via the SDK (it throttles/backoffs internally):

```swift
func refreshCallerId() async {
  try? await SecureNode.sync()
  try? await SecureNode.reloadCallDirectoryIfNeeded()
}
```

### 3) Notes
- The Call Directory Extension must exist in the app project and read from the same App Group.
- Contacts sync (photos) is attempted when permission is **authorized or not determined**.

