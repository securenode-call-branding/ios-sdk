# SecureNode iOS SDK

iOS SDK for SecureNode Active Caller Identity and Call Branding.

This SDK is **headless** (no UI). On iOS, production-grade caller identity uses **both**:
- **Call Directory Extension (CNCallDirectory)** for OS-managed caller ID **labels**
- **Contacts sync** (permission-gated) for SecureNode-managed contact **photos**

The SDK is designed to be **offline-safe, incremental, and scalable to multi-million device deployments**.

---

## Features

- ✅ **Call Directory snapshots (App Group)**  
  Atomic, validated snapshots for the extension to read (two-phase commit + rollback)

- ✅ **Call Directory reload policy**  
  Host app calls `SecureNode.reloadCallDirectoryIfNeeded()` — SDK controls throttling

- ✅ **Managed Contacts sync (optional)**  
  SecureNode-managed contacts with photos (never modifies existing user contacts)

- ✅ **Incremental sync**  
  Delta-based sync using a `since` cursor (no polling, no full refresh storms)

- ✅ **Local image caching**  
  Logos are served from `https://assets.securenode.io` and cached locally for instant display

- ✅ **Offline-first / call-safe**  
  Incoming calls never trigger network requests

- ✅ **Secure API key handling**  
  API keys stored in iOS Keychain

- ✅ **Thread-safe & call-safe**  
  Safe for multi-threaded and call-time execution paths

- ✅ **Call event reporting (optional, VoIP/CallKit)**  
  Use `SecureNodeSDK` to emit `/mobile/branding/event` and imprints when you own the call event

- 🧩 **Secure Voice / SIP (future add-on)**  
  VoIP dialler capability may be enabled later via flags (SIP engine not bundled)

---

## Installation

### Swift Package Manager

```swift
dependencies: [
  .package(
    url: "https://github.com/securenode-call-branding/ios-sdk.git",
    from: "1.0.0"
  )
]
```

---

## Quick Start

```swift
import SecureNodeSDK

SecureNode.configure(.init(
  apiURL: URL(string: "https://verify.securenode.io")!,
  apiKey: "your-api-key-here",
  appGroupId: "group.com.customer.app.securenode",
  callDirectoryExtensionBundleId: "com.customer.app.CallDirectoryExtension"
))
```

Branding logos are always served from `https://assets.securenode.io`.

---

## Sync Behaviour

- First sync is full; subsequent syncs use the stored `since` cursor
- Host-driven: call `SecureNode.sync()` on app launch or a scheduled task
- Never sync during incoming call handling

---

## Call event reporting (optional)

Use `SecureNodeSDK` for VoIP / CallKit flows where your app owns the call event.  
The SDK forwards outcomes to `/mobile/branding/event` and emits imprints when `assistIncomingCall(...)` applies branding.

```swift
import SecureNodeSDK

let sdk = SecureNodeSDK(config: SecureNodeConfig(
  apiURL: URL(string: "https://verify.securenode.io")!,
  apiKey: "your-api-key-here",
  campaignId: "campaign_123" // optional
))

sdk.recordCallEvent(
  phoneNumberE164: "+61412345678",
  outcome: "displayed",
  callOutcome: "ANSWERED",
  ringDurationSeconds: 12,
  callDurationSeconds: 180,
  callerNumberE164: "+61412345678",
  destinationNumberE164: "+61234567890"
)
```

Convenience fields map into event `meta`:
`call_event_id`, `caller_number_e164`, `destination_number_e164`, `observed_at_utc`, `branding_applied`,
`branding_profile_id`, `identity_type`, `ring_duration_seconds`, `call_duration_seconds`, `call_outcome`,
`return_call_detected`, `return_call_latency_seconds`.

Notes:
- The SDK does not derive call outcomes; provide them if your app knows them.
- `call_event_id` is generated if you do not supply one.

## Requirements

- iOS 13+
- Swift 5.5+
- Xcode 14+

---

## License

Apache-2.0
