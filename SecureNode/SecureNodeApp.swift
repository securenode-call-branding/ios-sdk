import SwiftUI
import Combine

// MARK: - API key: set your SecureNode API key here
private enum DemoConfig {
    /// Replace with your API key from the SecureNode dashboard (e.g. sn_live_... or sn_test_...).
    static let apiKey = "sn_live_de23756e5c16bcd94f763f5a8320ccb2"
    static let apiURLString = "https://api.securenode.io"
}

@main
struct SecureNodeApp: App {
    @State private var showIntroVideo = true

    var body: some Scene {
        WindowGroup {
            if showIntroVideo {
                IntroVideoView(onFinish: { showIntroVideo = false })
            } else {
                ContentView()
                    .environmentObject(DemoSdkHolder.shared)
            }
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
            campaignId: nil
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

    private init() {
        let key = DemoConfig.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.alertMessage = "Missing API key. Set DemoConfig.apiKey in SecureNodeApp.swift."
            }
        }
    }
}

