# Testing dialer and missed-call branding

The SDK applies branding on **two fronts**:

1. **Contacts** – Maintains an updated list of contacts **grouped by branding profile**: one contact per brand, with up to N phone numbers per contact (configurable). Avoids creating unnecessary contacts; incrementally synced via a registry. Requires Contacts permission and App Group.
2. **Dialler / Call Directory** – Feeds the system with **brand name and call reason** so the OS can display incoming and missed calls with the correct label and **bypass unknown-call and spam filtering**. Call Directory shows a single label per number (name, or "Name (reason)" when reason is set).

## What you need

1. **Call Directory extension** in your app (iOS only; not available in Simulator for real calls).
2. **App Group** shared between the main app and the extension.
3. **Synced branding** (numbers + brand names) so the SDK can build the Call Directory snapshot.

## Steps to test

### 1. Add the Call Directory extension

- In Xcode: **File → New → Target → Call Directory Extension**.
- Name it e.g. `SecureNodeCallDirectory`; bundle id e.g. `SecureNodeKit.SecureNode.CallDirectory`.

### 2. Enable App Groups

- **Main app target** → Signing & Capabilities → **+ Capability** → **App Groups** → add e.g. `group.SecureNodeKit.SecureNode`.
- **Call Directory extension target** → same App Group: `group.SecureNodeKit.SecureNode`.

### 3. Use the extension code

- Add the SDK to **both** the app and the extension target.
- In the extension target, use the handler from **Examples/SecureNodeCallDirectoryExtension/CallDirectoryHandler.swift**.
- Set `appGroupId` in that file to your App Group id (e.g. `group.SecureNodeKit.SecureNode`).

### 4. Configure the SDK with App Group and extension

When creating the SDK config, pass the same App Group and the extension’s bundle id:

```swift
let config = SecureNodeConfig(
    apiURL: url,
    apiKey: apiKey,
    campaignId: nil,
    appGroupId: "group.SecureNodeKit.SecureNode",
    callDirectoryExtensionBundleId: "SecureNodeKit.SecureNode.CallDirectory"
)
```

After each successful **sync**, the SDK will write the current branding snapshot into the App Group and call **reload** on the Call Directory extension. The system will then use that list for incoming calls and the missed-call list.

### 5. Run on a real device

- Call Directory does **not** work in Simulator for real incoming calls.
- Install the app on a **physical iPhone**.
- Ensure the API returns branding for the numbers you will call from (or use test numbers that exist in your synced set).
- **Sync** in the app (e.g. tap “Sync branding”) so the snapshot is written and the extension is reloaded.
- **Call the device** from a number that has branding in the sync response; the incoming screen and missed-call list should show the **brand name** as the label.

### 6. Contacts (grouped by profile)

When **appGroupId** is set, the SDK also runs **managed contacts sync** after each successful branding sync: contacts are **grouped by branding profile** (one contact per brand), with up to **maxPhoneNumbersPerContact** numbers per contact (default 50). Limits: **maxManagedContactProfiles** (default 1500). A registry in the App Group keeps the list incrementally updated (upsert/delete). Grant **Contacts** permission so the SDK can create/update these contacts.

**Logos / photos:** Only branding entries that have both **brand name and logo_url** are turned into managed contacts. For each such contact, the SDK downloads the logo from **logo_url**, resizes it to 256×256, and sets it as the contact’s **image** (photo). iOS then shows that photo in the Contacts app and on the **incoming call screen** when the caller’s number matches one of that contact’s numbers. Entries without a logo still get the **Call Directory** text label (name/reason) on the dialler and missed-call list, but no contact photo.

## Quick checklist

- [ ] Call Directory extension target added.
- [ ] Same App Group on app and extension.
- [ ] Extension handler uses `SecureNodeCallDirectorySnapshotReader` and your `appGroupId`.
- [ ] `SecureNodeConfig` includes `appGroupId` and `callDirectoryExtensionBundleId`.
- [ ] Sync runs (e.g. on launch or “Sync branding”); debug log shows “call directory reload: ok N entries”.
- [ ] Test on a **real device** with an incoming call from a number that has branding in the sync.
