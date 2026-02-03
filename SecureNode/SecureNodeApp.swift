import SwiftUI
import Combine
import CallKit
import Contacts

// MARK: - API key: set your SecureNode API key here
private enum DemoConfig {
    /// Replace with your API key from the SecureNode dashboard (e.g. sn_live_... or sn_test_...).
    static let apiKey = "sn_live_de23756e5c16bcd94f763f5a8320ccb2"
    static let apiURLString = "https://api.securenode.io"
}

private let hasSeenTrustEngineNoticeKey = "SecureNode.hasSeenTrustEngineNotice"
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
                DemoSdkHolder.shared.triggerSync()
                DemoSdkHolder.shared.schedulePermissionFailSafeCheck()
            } else if newPhase == .background {
                DemoSdkHolder.shared.cancelPermissionFailSafeCheck()
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
        .alert("Permissions needed", isPresented: Binding(
            get: { demo.showPermissionFailSafeAlert },
            set: { if !$0 { demo.dismissPermissionFailSafeAlert() } }
        )) {
            Button("Open Settings") { demo.openPermissionSettings() }
            Button("Not now", role: .cancel) { demo.dismissPermissionFailSafeAlert() }
        } message: {
            Text("SecureNode needs these permissions to verify caller identity and ensure incoming calls are verified.")
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
        self.addApiDebug("SDK ready \(DemoConfig.apiURLString)")
        return instance
    }()

    @Published var lastSyncMessage: String = "Ready"
    @Published var lastSyncCount: Int = 0
    @Published var syncedBranding: [BrandingInfo] = []
    @Published var alertMessage: String? = nil
    @Published var apiDebugLines: [String] = []
    @Published var showPermissionFailSafeAlert = false
    private var permissionFailSafeContactsNeeded = false
    private var permissionFailSafeCallDirectoryNeeded = false
    private var permissionFailSafeWorkItem: DispatchWorkItem?
    private let maxDebugLines = 50

    func loadSyncedBranding() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let list = self.sdk.listSyncedBranding()
            DispatchQueue.main.async { [weak self] in
                self?.syncedBranding = list
            }
        }
    }

    /// Trigger branding sync (automatic on app active; no button required).
    func triggerSync(completion: (() -> Void)? = nil) {
        // Set initial UI state on main
        DispatchQueue.main.async { [weak self] in
            self?.lastSyncMessage = "Syncing…"
            self?.addApiDebug("sync: start")
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
                        self.addApiDebug("sync: ok \(response.branding.count) items")
                        // loadSyncedBranding already uses a background queue internally
                        self.loadSyncedBranding()
                    case .failure(let error):
                        self.lastSyncMessage = "Error: \(error.localizedDescription)"
                        self.addApiDebug("sync: err \(error.localizedDescription)")
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
                        self.addApiDebug("call directory reload error: \(error.localizedDescription)")
                    } else {
                        self.addApiDebug("call directory reload: requested")
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

