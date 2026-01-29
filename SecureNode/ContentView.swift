import SwiftUI

struct ContentView: View {
    @EnvironmentObject var demo: DemoSdkHolder
    @State private var isSyncing = false
    @State private var isLookingUp = false
    @State private var lookupNumber = ""
    @State private var lookupResult: String = ""

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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("SecureNode")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { triggerInitialSync() }
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
            Text("API debug")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                    if let last = demo.apiDebugLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 120)
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var listContent: some View {
        Section {
                Button {
                    syncBranding()
                } label: {
                    HStack {
                        Text("Sync branding")
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
            } header: {
                Text("SDK demo")
            }
            .listRowBackground(Color.black.opacity(0.25))

            Section {
                if demo.syncedBranding.isEmpty {
                    Text("No contacts yet. Tap Sync branding above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(demo.syncedBranding.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.phoneNumberE164)
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Text(item.brandName ?? "—")
                                .font(.caption)
                                .lineLimit(1)
                        }
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
        demo.addApiDebug("app appeared")
        demo.loadSyncedBranding()
        syncBranding()
    }

    private func syncBranding() {
        isSyncing = true
        demo.lastSyncMessage = "Syncing…"
        demo.addApiDebug("sync: start")
        demo.sdk.syncBranding(since: nil) { result in
            Task { @MainActor in
                isSyncing = false
                switch result {
                case .success(let response):
                    demo.lastSyncCount = response.branding.count
                    demo.lastSyncMessage = "Synced \(response.branding.count) items"
                    demo.addApiDebug("sync: ok \(response.branding.count) items")
                    demo.loadSyncedBranding()
                case .failure(let error):
                    demo.lastSyncMessage = "Error: \(error.localizedDescription)"
                    demo.addApiDebug("sync: err \(error.localizedDescription)")
                }
            }
        }
    }

    private func lookupBranding() {
        let number = lookupNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty else { return }
        let normalized = number.hasPrefix("+") ? number : "+" + number
        isLookingUp = true
        lookupResult = "…"
        demo.addApiDebug("lookup: \(normalized)")
        demo.sdk.getBranding(for: normalized) { result in
            Task { @MainActor in
                isLookingUp = false
                switch result {
                case .success(let branding):
                    let name = branding.brandName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !name.isEmpty {
                        lookupResult = "Brand: \(name)"
                        demo.addApiDebug("lookup: ok \"\(name)\"")
                    } else {
                        lookupResult = "No brand for this number"
                        demo.addApiDebug("lookup: ok (no brand)")
                    }
                case .failure(let error):
                    lookupResult = "Error: \(error.localizedDescription)"
                    demo.addApiDebug("lookup: err \(error.localizedDescription)")
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

#Preview {
    ContentView()
        .environmentObject(DemoSdkHolder.shared)
}
