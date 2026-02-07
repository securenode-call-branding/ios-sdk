import SwiftUI
import Combine
import CallKit
import Contacts
import Network

// MARK: - API key: from Info.plist (Xcode Cloud injects via run script + SECURENODE_API_KEY) or fallback for local dev
private enum DemoConfig {
    private static let fallbackApiKey = "sn_live_de23756e5c16bcd94f763f5a8320ccb2"
    private static let fallbackApiURL = "https://api.securenode.io"
    static var apiKey: String {
        guard let s = Bundle.main.infoDictionary?["SecureNodeAPIKey"] as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallbackApiKey }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static var apiURLString: String {
        guard let s = Bundle.main.infoDictionary?["SecureNodeAPIURL"] as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallbackApiURL }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private let hasSeenTrustEngineNoticeKey = "SecureNode.hasSeenTrustEngineNotice"
private let hasExitedAfterFirstSyncKey = "SecureNode.hasExitedAfterFirstSync"
private let callDirectoryBundleId = "SecureNodeKit.SecureNode.CallDirectory"

@main
struct SecureNodeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(hasSeenTrustEngineNoticeKey) private var hasSeenTrustEngineNotice = false
    @State private var showIntroVideo = true

    var body: some Scene {
        WindowGroup {
            SecureNodeRootView(hasSeenTrustEngineNotice: $hasSeenTrustEngineNotice, showIntroVideo: $showIntroVideo)
                .environmentObject(DemoSdkHolder.shared)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                DemoSdkHolder.shared.sdk.requestContactsPermissionIfNeeded()
                DemoSdkHolder.shared.sdk.primeCallDirectoryIfNeeded()
                DemoSdkHolder.shared.checkConnectivityAndSync()
                DemoSdkHolder.shared.schedulePermissionFailSafeCheck()
            } else if newPhase == .background {
                DemoSdkHolder.shared.cancelPermissionFailSafeCheck()
                DemoSdkHolder.shared.stopConnectivityWaiting()
            }
        }
    }
}

/// Root view so the permission fail-safe alert can be shown from any screen.
private struct SecureNodeRootView: View {
    @EnvironmentObject var demo: DemoSdkHolder
    @Binding var hasSeenTrustEngineNotice: Bool
    @Binding var showIntroVideo: Bool

    var body: some View {
        Group {
            if !hasSeenTrustEngineNotice {
                TrustEngineNoticeView(onContinue: { hasSeenTrustEngineNotice = true })
            } else if showIntroVideo {
                IntroVideoView(onFinish: { showIntroVideo = false })
            } else {
                ContentView()
            }
        }
        .alert("Verified Caller Names", isPresented: Binding(
            get: { demo.showPermissionFailSafeAlert },
            set: { if !$0 { demo.dismissPermissionFailSafeAlert() } }
        )) {
            Button("Open Settings") { demo.openPermissionSettings() }
            Button("Not now", role: .cancel) { demo.dismissPermissionFailSafeAlert() }
        } message: {
            Text("Enable Verified Caller Names to display trusted business identities on incoming calls. Calls are never blocked, intercepted, or recorded.")
        }
    }
}

/// Holds SDK instance and demo state; init configures SDK once.
final class DemoSdkHolder: ObservableObject {
    static let shared = DemoSdkHolder()

    lazy var sdk: SecureNodeSDK = {
        let apiURL = URL(string: DemoConfig.apiURLString) ?? SecureNodeConfig.defaultBaseURL
        let config = SecureNodeConfig(
            apiURL: apiURL,
            apiKey: DemoConfig.apiKey,
            campaignId: nil,
            appGroupId: "group.SecureNodeKit.SecureNode",
            callDirectoryExtensionBundleId: "SecureNodeKit.SecureNode.CallDirectory"
        )
        let options = SecureNodeOptions(debugLog: { [weak self] line in
            self?.addApiDebug(line)
        })
        let instance = SecureNodeSDK(config: config, options: options)
        self.addApiDebug("(sdk:ready)")
        return instance
    }()

    enum ApiReachability {
        case unknown
        case checking
        case reachable
        case unreachable
    }

    @Published var lastSyncMessage: String = "Ready"
    @Published var lastSyncCount: Int = 0
    @Published var syncedBranding: [BrandingInfo] = []
    @Published var alertMessage: String? = nil
    @Published var apiDebugLines: [String] = []
    @Published var apiReachability: ApiReachability = .unknown
    @Published var showPermissionFailSafeAlert = false
    @Published var callDirectoryExtensionOn: Bool = false
    @Published var callDirectoryEntryCount: Int? = nil
    private var permissionFailSafeContactsNeeded = false
    private var permissionFailSafeCallDirectoryNeeded = false
    private var permissionFailSafeWorkItem: DispatchWorkItem?
    private let maxDebugLines = 50
    private let connectivityQueue = DispatchQueue(label: "SecureNode.connectivity")
    private var pathMonitor: NWPathMonitor?
    private var reProbeTimer: DispatchSourceTimer?

    func loadSyncedBranding() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let list = self.sdk.listSyncedBranding()
            DispatchQueue.main.async { [weak self] in
                self?.syncedBranding = list
            }
        }
    }

    // MARK: - Connectivity: probe API before sync; wait for network if unreachable

    /// Probe API (lightweight GET). Any HTTP response = reachable; timeout/connection error = unreachable.
    private func probeApiReachability(completion: @escaping (Bool) -> Void) {
        let base = DemoConfig.apiURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let syncPath = base.hasSuffix("/api") ? "\(base)/mobile/branding/sync" : "\(base)/api/mobile/branding/sync"
        guard let url = URL(string: syncPath) else { completion(false); return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(DemoConfig.apiKey, forHTTPHeaderField: "X-API-Key")
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { _, response, error in
            let reachable: Bool
            if let res = response as? HTTPURLResponse {
                reachable = (100...599).contains(res.statusCode)
            } else {
                reachable = (error == nil)
            }
            DispatchQueue.main.async { completion(reachable) }
        }.resume()
    }

    /// Check connectivity; if reachable run sync; if not, wait for network change then retry.
    func checkConnectivityAndSync() {
        DispatchQueue.main.async { [weak self] in
            self?.apiReachability = .checking
        }
        probeApiReachability { [weak self] reachable in
            guard let self = self else { return }
            if reachable {
                self.apiReachability = .reachable
                self.addApiDebug("api: reachable")
                self.triggerSync()
            } else {
                self.apiReachability = .unreachable
                self.addApiDebug("api: unreachable, waiting for network")
                self.startConnectivityWaiting()
            }
        }
    }

    private func startConnectivityWaiting() {
        stopConnectivityWaiting()
        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            self?.connectivityQueue.async { self?.reProbeWhenReachable() }
        }
        pathMonitor?.start(queue: connectivityQueue)
        let timer = DispatchSource.makeTimerSource(queue: connectivityQueue)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            self?.reProbeWhenReachable()
        }
        timer.resume()
        reProbeTimer = timer
    }

    private func reProbeWhenReachable() {
        probeApiReachability { [weak self] reachable in
            guard let self = self, reachable else { return }
            self.stopConnectivityWaiting()
            self.addApiDebug("api: reachable (retry)")
            self.apiReachability = .reachable
            self.triggerSync()
        }
    }

    func stopConnectivityWaiting() {
        pathMonitor?.cancel()
        pathMonitor = nil
        reProbeTimer?.cancel()
        reProbeTimer = nil
    }

    /// Refresh Call Directory extension status and snapshot entry count (e.g. when returning from Settings).
    func refreshCallDirectoryStatus() {
        let count = sdk.getCallDirectorySnapshotEntryCount()
        DispatchQueue.main.async { [weak self] in
            self?.callDirectoryEntryCount = count
        }
        sdk.getCallDirectoryExtensionEnabled { [weak self] enabled in
            self?.callDirectoryExtensionOn = enabled
        }
    }

    /// Trigger branding sync (automatic on app active; no button required).
    func triggerSync(completion: (() -> Void)? = nil) {
        // Set initial UI state on main
        DispatchQueue.main.async { [weak self] in
            self?.lastSyncMessage = "Syncing…"
        }

        sdk.syncBranding(since: nil) { [weak self] result in
            guard let self = self else { completion?(); return }

            // Perform heavy/non-UI work off the main thread first
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.performPostSyncWork(result: result)

                // Now update UI on main
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { completion?(); return }
                    switch result {
                    case .success(let response):
                        self.lastSyncCount = response.branding.count
                        self.lastSyncMessage = "Synced \(response.branding.count) items"
                        self.loadSyncedBranding()
                        self.refreshCallDirectoryStatus()
                        if !UserDefaults.standard.bool(forKey: hasExitedAfterFirstSyncKey) {
                            UserDefaults.standard.set(true, forKey: hasExitedAfterFirstSyncKey)
                            self.lastSyncMessage = "First sync complete. Closing so you can reopen and verify."
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                exit(0)
                            }
                        }
                    case .failure(let error):
                        self.lastSyncMessage = "Error: \(error.localizedDescription)"
                        self.addApiDebug("(sync:err) \(error.localizedDescription)")
                    }
                    completion?()
                }
            }
        }
    }

    func addApiDebug(_ line: String) {
        if Thread.isMainThread {
            apiDebugLines.append(line)
            if apiDebugLines.count > maxDebugLines {
                apiDebugLines.removeFirst(apiDebugLines.count - maxDebugLines)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.apiDebugLines.append(line)
                if self.apiDebugLines.count > self.maxDebugLines {
                    self.apiDebugLines.removeFirst(self.apiDebugLines.count - self.maxDebugLines)
                }
            }
        }
    }

    /// Full debug log text for sharing (e.g. email). Include sync state and all API debug lines.
    func fullDebugLogText() -> String {
        let header = """
        SecureNode Trust Engine — Debug Log
        \(ISO8601DateFormatter().string(from: Date()))
        Sync: \(lastSyncMessage) | Contacts: \(syncedBranding.count) | Last count: \(lastSyncCount)

        """
        let lines = apiDebugLines.joined(separator: "\n")
        return header + lines
    }

    /// Perform heavy/non-UI follow-up work after a sync completes.
    /// Run only from a background queue. Do not update UI/@Published properties here.
    private func performPostSyncWork<T>(result: Result<T, Error>) {
        switch result {
        case .success(_):
            // Example: If contacts or photos need to be written, do it here using CNContactStore/CNSaveRequest
            // Ensure you fetch fresh contacts before update to avoid CNErrorDomain Code=200 (record does not exist).
            // If an update fails with CNErrorDomain 200, consider falling back to add or skipping based on your sync intent.

            // Example: Reload Call Directory extension off the main thread, as it can block.
            #if canImport(CallKit)
            let bundleId = "SecureNodeKit.SecureNode.CallDirectory"
            DispatchQueue.global(qos: .utility).async {
                let manager = CXCallDirectoryManager.sharedInstance
                manager.reloadExtension(withIdentifier: bundleId) { error in
                    if let error = error {
                        self.addApiDebug("(cd_reload:err) \(error.localizedDescription)")
                    } else {
                        self.addApiDebug("(cd_reload:ok)")
                    }
                }
            }
            #endif

            // Example: Any database/file I/O related to `response.branding` should be done here.

        case .failure:
            break
        }
    }

    // MARK: - Permission fail-safe (demo: check ~1 min after active, prompt to open Settings if needed)

    func schedulePermissionFailSafeCheck() {
        cancelPermissionFailSafeCheck()
        let item = DispatchWorkItem { [weak self] in
            self?.runPermissionFailSafeCheck()
        }
        permissionFailSafeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: item)
    }

    func cancelPermissionFailSafeCheck() {
        permissionFailSafeWorkItem?.cancel()
        permissionFailSafeWorkItem = nil
    }

    private func runPermissionFailSafeCheck() {
        permissionFailSafeWorkItem = nil
        let contactsAuthorized = CNContactStore.authorizationStatus(for: .contacts) == .authorized
        if !contactsAuthorized {
            sdk.requestContactsPermissionIfNeeded()
        }
        CXCallDirectoryManager.sharedInstance.getEnabledStatusForExtension(withIdentifier: callDirectoryBundleId) { [weak self] status, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let callDirectoryEnabled = (status == .enabled)
                if contactsAuthorized && callDirectoryEnabled { return }
                self.permissionFailSafeContactsNeeded = !contactsAuthorized
                self.permissionFailSafeCallDirectoryNeeded = !callDirectoryEnabled
                self.showPermissionFailSafeAlert = true
            }
        }
    }

    func openPermissionSettings() {
        if permissionFailSafeContactsNeeded {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
        if permissionFailSafeCallDirectoryNeeded {
            let delay = permissionFailSafeContactsNeeded ? 1.5 : 0.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                CXCallDirectoryManager.sharedInstance.openSettings { _ in }
                self?.dismissPermissionFailSafeAlert()
            }
            return
        }
        dismissPermissionFailSafeAlert()
    }

    func dismissPermissionFailSafeAlert() {
        showPermissionFailSafeAlert = false
        permissionFailSafeContactsNeeded = false
        permissionFailSafeCallDirectoryNeeded = false
    }

    private init() {
        let key = DemoConfig.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.alertMessage = "Missing API key. Set DemoConfig.apiKey in SecureNodeApp.swift."
            }
        }
    }
}

