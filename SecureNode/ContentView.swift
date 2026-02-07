import SwiftUI
import CallKit

struct ContentView: View {
    @EnvironmentObject var demo: DemoSdkHolder
    @State private var isSyncing = false
    @State private var isLookingUp = false
    @State private var lookupNumber = ""
    @State private var lookupResult: String = ""
    @State private var selectedContact: BrandingInfo?
    @State private var showShareLog = false
    @State private var logTextToShare: String = ""

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                NavigationStack { contentWithBackground }
            } else {
                NavigationView { contentWithBackground }
            }
        }
    }

    @ViewBuilder
    private var contentWithBackground: some View {
        ZStack {
            Image("Background")
                .resizable()
                .scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
                .ignoresSafeArea(.all)
            Color.black.opacity(0.3)
                .ignoresSafeArea(.all)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded { _ in
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                )
            contentList
            if selectedContact != nil {
                contactDetailOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("SecureNode")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            triggerInitialSync()
            demo.refreshCallDirectoryStatus()
        }
        .alert("Notice", isPresented: Binding(get: { demo.alertMessage != nil }, set: { newValue in if !newValue { demo.alertMessage = nil } })) {
            Button("OK", role: .cancel) { demo.alertMessage = nil }
        } message: {
            Text(demo.alertMessage ?? "")
        }
    }

    @ViewBuilder
    private var contentList: some View {
        VStack(spacing: 0) {
            List {
                listContent
            }
            .modifier(ListClearBackground())
            .foregroundStyle(.white)
            .modifier(ScrollDismissesKeyboardModifier())
            debugPanel
        }
    }

    @ViewBuilder
    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectivityColor)
                        .frame(width: 8, height: 8)
                    Text(connectivityLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("API debug")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Email logs") {
                    logTextToShare = demo.fullDebugLogText()
                    showShareLog = true
                }
                .font(.caption2)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(demo.apiDebugLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: demo.apiDebugLines.count) { _ in
                    DispatchQueue.main.async {
                        if let last = demo.apiDebugLines.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 120)
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: $showShareLog) {
            ShareSheet(activityItems: [logTextToShare])
        }
    }

    private var connectivityColor: Color {
        switch demo.apiReachability {
        case .reachable: return .green
        case .unreachable: return .red
        case .checking, .unknown: return .gray
        }
    }

    private var connectivityLabel: String {
        switch demo.apiReachability {
        case .reachable: return "API: OK"
        case .unreachable: return "API: Unavailable"
        case .checking: return "API: Checking…"
        case .unknown: return "API: —"
        }
    }

    @ViewBuilder
    private var contactDetailOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { selectedContact = nil }
            if let contact = selectedContact {
                VStack(spacing: 12) {
                    if let urlString = contact.logoUrl, let url = URL(string: urlString) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                            case .failure:
                                Image(systemName: "person.circle.fill")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                            default:
                                ProgressView()
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.secondary)
                    }
                    Text(contact.brandName ?? "—")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(contact.phoneNumberE164)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let reason = contact.callReason, !reason.isEmpty {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(24)
                .frame(maxWidth: 280)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .onTapGesture { selectedContact = nil }
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        Section {
                Button {
                    syncBranding()
                } label: {
                    HStack {
                        Text("Sync now")
                        Spacer()
                        if isSyncing {
                            ProgressView()
                        }
                    }
                }
                .disabled(isSyncing)

                Text(demo.lastSyncMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Syncs automatically when app opens or returns to foreground.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("SDK demo")
            }
            .listRowBackground(Color.black.opacity(0.25))

            Section {
                Button("Enable Verified Caller Names") {
                    CXCallDirectoryManager.sharedInstance.openSettings { _ in }
                }
                .buttonStyle(.plain)
                HStack {
                    Text("Extension:")
                        .font(.caption)
                    Text(demo.callDirectoryExtensionOn ? "On" : "Off")
                        .font(.caption)
                        .foregroundStyle(demo.callDirectoryExtensionOn ? .green : .secondary)
                    Spacer()
                    if let n = demo.callDirectoryEntryCount {
                        Text("\(n) entries in dialer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Turn on Verified Caller Names in Phone settings to display trusted business identities on incoming calls. Names can also come from Contacts; to see if a name is from Call Directory, turn the extension off and call again—if the name disappears, it was from Call Directory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Verified Caller Names")
            }
            .listRowBackground(Color.black.opacity(0.25))

            Section {
                if demo.syncedBranding.isEmpty {
                    Text("No contacts yet. Tap Sync branding above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(demo.syncedBranding.enumerated()), id: \.offset) { _, item in
                        Button {
                            selectedContact = item
                        } label: {
                            HStack {
                                Text(item.phoneNumberE164)
                                    .font(.system(.caption, design: .monospaced))
                                Spacer()
                                Text(item.brandName ?? "—")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Contacts (\(demo.syncedBranding.count))")
            }
            .listRowBackground(Color.black.opacity(0.25))

            Section {
                TextField("E.164 number", text: $lookupNumber)
                    .keyboardType(.phonePad)
                Button("Lookup branding") {
                    lookupBranding()
                }
                .buttonStyle(.plain)
                .disabled(lookupNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLookingUp)
                if isLookingUp {
                    ProgressView().padding(.vertical, 2)
                }
                if !lookupResult.isEmpty {
                    Text(lookupResult)
                        .font(.caption)
                }
            } header: {
                Text("Lookup")
            }
            .listRowBackground(Color.black.opacity(0.25))
    }

    private func triggerInitialSync() {
        demo.addApiDebug("(app:appeared)")
        demo.loadSyncedBranding()
    }

    private func syncBranding() {
        isSyncing = true
        demo.triggerSync { isSyncing = false }
    }

    private func lookupBranding() {
        let number = lookupNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty else { return }
        let normalized = number.hasPrefix("+") ? number : "+" + number
        isLookingUp = true
        lookupResult = "…"
        demo.sdk.getBranding(for: normalized) { result in
            Task { @MainActor in
                isLookingUp = false
                switch result {
                case .success(let branding):
                    let name = branding.brandName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !name.isEmpty {
                        lookupResult = "Brand: \(name)"
                        demo.addApiDebug("(lookup:ok)")
                    } else {
                        lookupResult = "No brand for this number"
                        demo.addApiDebug("(lookup:ok)")
                    }
                case .failure(let error):
                    lookupResult = "Error: \(error.localizedDescription)"
                    demo.addApiDebug("(lookup:err) \(error.localizedDescription)")
                }
            }
        }
    }
}

private struct ListClearBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}

private struct ScrollDismissesKeyboardModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollDismissesKeyboard(.immediately)
        } else {
            content
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
        .environmentObject(DemoSdkHolder.shared)
}
