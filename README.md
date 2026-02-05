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

- ✅ **Presence heartbeats (SecureNodeSDK)**  
  Periodic presence updates to the API (`mobile/device/presence`) so the system knows the device is active; sent every 5 minutes and on each successful sync

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
  apiURL: URL(string: "https://edge.securenode.io")!,
  apiKey: "your-api-key-here",
  appGroupId: "group.com.customer.app.securenode",
  callDirectoryExtensionBundleId: "com.customer.app.CallDirectoryExtension"
))
```

Branding logos are always served from `https://assets.securenode.io`.

---

## API Endpoints (device cache & usage)

The SDK hits these endpoints against your base URL (e.g. `https://edge.securenode.io`), trying both `{base}/...` and `{base}/api/...` so `/api/mobile/...` is used when the API is mounted under `/api`.

### 1. Active Caller Identity Sync (device cache)

- **Full sync:** `GET {base}/api/mobile/branding/sync`  
  Headers: `X-API-Key`, `Content-Type: application/json`
- **Incremental sync:** `GET {base}/api/mobile/branding/sync?since=2024-01-01T00:00:00Z`  
  Optional query: `device_id`

**Response:** `branding` (array of identity objects), `synced_at` (ISO), optional `config` (e.g. `voip_dialer_enabled`, `branding_enabled`).  
Each branding item: `phone_number_e164`, `brand_name`, `logo_url`, `call_reason`, `updated_at`, optional `brand_id`.

### 2. Identity Lookup (fallback)

- **Request:** `GET {base}/api/mobile/branding/lookup?e164=%2B1234567890`  
  Optional query: `device_id`  
  Headers: `X-API-Key`, `Content-Type: application/json`

**Response:** Single identity: `e164`, `brand_name`, `logo_url`, `call_reason` (and optional `updated_at`). Empty or 404 means no match.

### 3. Usage Reporting (billable)

- **Request:** `POST {base}/api/mobile/branding/event`  
  Headers: `X-API-Key`, `Content-Type: application/json`  
  Body: `phone_number_e164`, `outcome` (e.g. `"displayed"`), `surface` (e.g. `"display"`), `displayed_at` (ISO). Optional: `device_id`, `event_key`, `meta`.

**Response:** `success`, `event_id`, `displayed_at`.

---

## Field constraints & image caching

**Field length constraints** (enforced server-side; SDK clamps when storing locally):

| Field | Min | Max | Notes |
|-------|-----|-----|-------|
| phone_number_e164 | 1 | 20 | E.164 (e.g. +1234567890) |
| brand_name | 1 | 100 | Display name on incoming calls |
| logo_url | 1 | 2048 | Optional; valid URL |
| call_reason | 1 | 200 | Optional |

**Image cache (iOS):**

- **Path:** `Library/Caches/SecureNodeBranding/`
- **Format:** PNG (or response format); files use `.png` extension
- **Naming:** Base64-encoded URL (sanitized) + `.png`
- **Strategy:** Check cache first; on miss, download and save for later
- **Clear cache:** `sdk.clearImageCache()` when needed

---

## Sync Behaviour

- First sync is full; subsequent syncs use the stored `since` cursor
- Host-driven: call `SecureNode.sync()` on app launch or a scheduled task
- Never sync during incoming call handling

---

## Background sync (SecureNodeSDK, iOS 13+)

When using **SecureNodeSDK** (VoIP/CallKit path), the SDK registers a **BGAppRefreshTask** so branding can sync after the app is suspended or the device restarts. The system may wake the app periodically (e.g. every 30+ minutes) to run a sync; timing is controlled by iOS.

**Host app setup:**

1. **Info.plist**  
   Add the SDK’s task identifier to your app’s Info.plist so background refresh is allowed:
   - Key: `BGTaskSchedulerPermittedIdentifiers` (Array)
   - Item: `com.securenode.branding.sync`  
   (Or use the constant `SecureNodeSDK.backgroundRefreshTaskIdentifier`.)

2. **Create the SDK at launch**  
   Instantiate `SecureNodeSDK` in `application(_:didFinishLaunchingWithOptions:)` (or as soon as the app runs). When the app is woken for a background task, the SDK must already exist so the task handler can run sync.

No extra code is required: the SDK registers and schedules the task in `init`, uses incremental sync when a `since` cursor is stored, and reschedules after each successful sync.

---

## Presence heartbeats (SecureNodeSDK)

When using **SecureNodeSDK**, the SDK sends **presence update heartbeats** to the API so the system can show the device as active ("present").

- **Endpoint:** `POST mobile/device/presence` (or `POST api/mobile/device/presence` depending on base URL).
- **Payload:** `device_id`, `observed_at` (ISO), optional `platform`, `os_version`, `last_synced_at`.
- **When:** Every 5 minutes (timer) and on each successful branding sync.

No host code is required; the SDK starts the heartbeat timer in `init`. The backend can use these requests to display "last seen" or "active" per device in the portal.

---

## Call event reporting (optional)

Use `SecureNodeSDK` for VoIP / CallKit flows where your app owns the call event.  
The SDK forwards outcomes to `/mobile/branding/event` and emits imprints when `assistIncomingCall(...)` applies branding.

**Convenience APIs (reporting & outcomes):**

- **`recordCallSeen(...)`** — Baseline "seen" when identity is displayed; returns `event_id` (call_id) in completion. Use `callOutcome` values your exports expect (e.g. ANSWERED, MISSED, REJECTED).
- **`recordMissedCall(...)`** — Missed-call outcome.
- **`recordCallReturned(..., callId:)`** — Follow-up attribution; pass the earlier call_id from `recordCallSeen`/`recordMissedCall`.

```swift
// Example: record seen, then use event_id for return attribution
sdk.recordCallSeen(
  phoneNumberE164: "+61412345678",
  brandingDisplayed: true,
  callOutcome: "ANSWERED",
  ringDurationSeconds: 12,
  callDurationSeconds: 180,
  callerNumberE164: "+61412345678",
  destinationNumberE164: "+61234567890"
) { result in
  if case .success(let resp) = result, let callId = resp.eventId {
    // Later, if user returns the call:
    sdk.recordCallReturned(phoneNumberE164: "+61412345678", callId: callId, returnCallLatencySeconds: 120)
  }
}
```

Event `meta` fields: `call_event_id`, `caller_number_e164`, `destination_number_e164`, `observed_at_utc`, `branding_applied`, `branding_profile_id`, `identity_type`, `ring_duration_seconds`, `call_duration_seconds`, `call_outcome`, `return_call_detected`, `return_call_latency_seconds`.

For full control use `recordCallEvent(...)`; the SDK does not derive call outcomes — provide them when your app knows them.

## Requirements

- iOS 13+
- Swift 5.5+
- Xcode 14+

---

## License

Apache-2.0
