# Distributing the SecureNode Demo App

## Quick: TestFlight (beta testing)

1. **App Store Connect** (one-time): [App Store Connect](https://appstoreconnect.apple.com) → My Apps → + → New App. iOS, name e.g. "SecureNode Demo", bundle ID **SecureNodeKit.SecureNode**, SKU e.g. `securenode-demo`.
2. **Archive:** Xcode → open `SecureNode.xcodeproj` → scheme **SecureNode** → destination **Any iOS Device (arm64)** → Product → Archive.
3. **Upload:** Organizer → select the new archive → Distribute App → App Store Connect → Upload. Finish the wizard.
4. **TestFlight:** App Store Connect → your app → TestFlight. When the build appears (often 5–15 min), add Internal testers and/or create an External group. Install the **TestFlight** app on your device and open the invite or the build from TestFlight.

---

## API key via Xcode Cloud (update fleet from one place)

The app reads the API key from **Info.plist** (`SecureNodeAPIKey`, `SecureNodeAPIURL`). For Xcode Cloud builds you can inject the key from **Shared Environment Variables** so you can rotate it without changing code:

1. In your CI portal (Xcode Cloud): **Settings** → **Shared Environment Variables** → add **SECURENODE_API_KEY** (and optionally **SECURENODE_API_URL**). Mark as secret if available.
2. The SecureNode target has a **Run Script** phase “Inject Xcode Cloud API key” that, when those env vars are set, writes them into `Info.plist` before the app is built.
3. Rebuild and distribute (e.g. TestFlight). Devices that install that build get the key that was in the env at build time. To update the fleet, change the variable and run a new build.

Local builds use the values in `Info.plist` (or the fallback in code) when the env vars are not set.

---

## Quick: Ad Hoc IPA (single file for manual install)

1. **Register devices** (one-time per device): [Apple Developer](https://developer.apple.com/account) → Certificates, Identifiers & Profiles → **Devices** → + → add the tester’s device name and **UDID**. (UDID: device connected to Mac → Finder → select device → click serial number until UDID appears; or Settings → General → About on device, or use a UDID lookup site.)
2. **Archive:** Xcode → open `SecureNode.xcodeproj` → scheme **SecureNode** → destination **Any iOS Device (arm64)** → **Product → Archive**.
3. **Export IPA:** Organizer → select the archive → **Distribute App** → **Ad Hoc** → Next → **Automatically manage signing** → Next → **Export**. Choose a folder; Xcode creates **SecureNode.ipa**.
4. **Send & install:** Send the `.ipa` (e.g. email, link, USB). Install on a **registered** device: connect to a Mac → open **Finder** → select the device → drag the `.ipa` onto the app list, or use **Apple Configurator**. The device must be in the provisioning profile (step 1).

---

## Option 1: Export an IPA (file you can distribute)

**Requirements:** Apple Developer account, device UDIDs for Ad Hoc.

1. **Archive in Xcode**
   - Open `SecureNode.xcodeproj` in Xcode.
   - Select scheme **SecureNode** and destination **Any iOS Device (arm64)** (not a simulator).
   - Menu: **Product → Archive**.
   - Wait for the archive to finish; Organizer opens.

2. **Export the IPA**
   - In Organizer, select the new archive → **Distribute App**.
   - **App Store Connect** → Next (for TestFlight / App Store),  
     **or Ad Hoc** → Next (for a file to install on registered devices only).
   - Choose **Automatically manage signing** (or your provisioning profile).
   - Next → Export. Pick a folder; Xcode creates `SecureNode.ipa` there.

3. **Sharing the file**
   - **Ad Hoc IPA:** Share the `.ipa` and have testers install via Finder (Mac), Apple Configurator, or a link from a distribution service. Devices must be registered in your Apple Developer account.
   - **Enterprise:** If you have an Enterprise account, you can choose **Enterprise** in Distribute App and distribute the IPA via your own hosting (per Apple’s Enterprise agreement).

---

## Option 2: TestFlight (Apple’s beta distribution)

**Requirements:** Apple Developer account ($99/year), app record in App Store Connect.

1. **Create the app in App Store Connect** (one-time)
   - Go to [App Store Connect](https://appstoreconnect.apple.com) → **My Apps** → **+** → **New App**.
   - Platform: iOS. Name (e.g. SecureNode Demo), bundle ID: `SecureNodeKit.SecureNode`, SKU (e.g. `securenode-demo`). Create.

2. **Archive and upload**
   - In Xcode: **Product → Archive** (scheme SecureNode, destination Any iOS Device).
   - In Organizer: select the archive → **Distribute App** → **App Store Connect** → **Upload**.
   - Complete the steps (signing, options). Upload. Wait for processing (often 5–15 minutes).

3. **Enable TestFlight**
   - App Store Connect → your app → **TestFlight** tab.
   - When the build appears, add **Internal** testers (same team) and/or **External** testers (group, up to 10,000; first external group needs a short Beta App Review).
   - Testers install **TestFlight** from the App Store, then open the invite link or the TestFlight app to install your build.

4. **Later builds**
   - Archive again in Xcode → Distribute App → Upload. New build shows in TestFlight; testers get updates from the TestFlight app.

---

## Checklist before archiving

- **Signing:** Xcode → SecureNode target → **Signing & Capabilities**. Team set, “Automatically manage signing” on (or correct provisioning profile).
- **Bundle ID:** Must match App Store Connect app if using TestFlight (e.g. `SecureNodeKit.SecureNode`).
- **Device:** Archive with **Any iOS Device (arm64)**; simulator builds cannot be exported for distribution or TestFlight.

If you only need a **file to hand to someone**, use **Option 1** with **Ad Hoc** and register their device UDIDs. For **easy beta testing by many people**, use **Option 2** (TestFlight).
