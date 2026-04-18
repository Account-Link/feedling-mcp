import ActivityKit
import ReplayKit
import SwiftUI

// MARK: - Tab enum

enum AppTab: Int {
    case chat = 0
    case identity = 1
    case garden = 2
    case settings = 3
}

// MARK: - Root view (TabView)

struct ContentView: View {
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var identityViewModel: IdentityViewModel
    @EnvironmentObject var memoryViewModel: MemoryViewModel

    var body: some View {
        TabView(selection: $router.selectedTab) {
            ChatView()
                .environmentObject(chatViewModel)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(AppTab.chat)

            IdentityView()
                .environmentObject(identityViewModel)
                .tabItem { Label("Identity", systemImage: "person.crop.square.filled.and.at.rectangle") }
                .tag(AppTab.identity)

            MemoryGardenView()
                .environmentObject(memoryViewModel)
                .tabItem { Label("Garden", systemImage: "leaf.fill") }
                .tag(AppTab.garden)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .tint(.cyan)
        .preferredColorScheme(.dark)
        // T2.5: Auto-navigate to Identity on first bootstrap
        .onChange(of: identityViewModel.didJustBootstrap) { didBootstrap in
            if didBootstrap {
                router.selectedTab = .identity
            }
        }
    }
}

// MARK: - Router

class AppRouter: ObservableObject {
    @Published var selectedTab: AppTab = .chat
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var lam: LiveActivityManager
    @ObservedObject private var api = FeedlingAPI.shared

    // Self-hosted draft fields (only persisted when user taps Save)
    @State private var selfHostedURL: String = ""
    @State private var selfHostedKey: String = ""
    @State private var showCopiedToast: String? = nil

    private let mockStates: [ScreenActivityAttributes.ContentState] = [
        .init(title: "OpenClaw",
              body: "45 min on TikTok. That's your entertainment budget.",
              data: ["top_app": "TikTok", "minutes": "45"],
              updatedAt: Date()),
        .init(title: "OpenClaw",
              body: "Deep work mode. 95 min in Figma.",
              data: ["top_app": "Figma", "minutes": "95"],
              updatedAt: Date()),
        .init(title: "OpenClaw",
              body: "28 min on Instagram. Wrap it up?",
              data: ["top_app": "Instagram", "minutes": "28"],
              updatedAt: Date()),
    ]
    @State private var mockIndex = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // Screen Recording Button
                VStack(spacing: 6) {
                    Text("SCREEN RECORDING")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                    ZStack {
                        BroadcastPickerView()
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
                .background(Color(UIColor.systemGroupedBackground))

                List {
                    // Storage toggle
                    Section("Storage") {
                        Picker("Backend", selection: $api.storageMode) {
                            Text("Feedling Cloud").tag(FeedlingAPI.StorageMode.cloud)
                            Text("Self-hosted").tag(FeedlingAPI.StorageMode.selfHosted)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: api.storageMode) { newMode in
                            if newMode == .cloud {
                                api.configureCloud()
                                Task { await api.ensureRegisteredIfCloud() }
                            }
                        }

                        if api.storageMode == .selfHosted {
                            TextField("https://my-vps.example:5001", text: $selfHostedURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.caption.monospaced())
                                .onAppear { selfHostedURL = api.baseURL }
                            TextField("API key", text: $selfHostedKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.caption.monospaced())
                                .onAppear { selfHostedKey = api.apiKey }
                            Button("Save self-hosted config") {
                                api.configureSelfHosted(url: selfHostedURL, apiKey: selfHostedKey)
                                showToast("Saved")
                            }
                            .disabled(selfHostedURL.isEmpty)
                        }
                    }

                    // Agent setup
                    Section("Agent Setup") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("MCP connection string")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(api.mcpConnectionString)
                                .font(.caption2.monospaced())
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color(UIColor.tertiarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Button {
                                UIPasteboard.general.string = api.mcpConnectionString
                                showToast("Copied MCP string")
                            } label: {
                                Label("Copy MCP string", systemImage: "doc.on.doc")
                            }
                        }
                        .padding(.vertical, 4)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("OpenClaw env vars")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(api.envExportBlock)
                                .font(.caption2.monospaced())
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color(UIColor.tertiarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Button {
                                UIPasteboard.general.string = api.envExportBlock
                                showToast("Copied env vars")
                            } label: {
                                Label("Copy env vars", systemImage: "doc.on.doc")
                            }
                        }
                        .padding(.vertical, 4)

                        if api.storageMode == .cloud {
                            Button(role: .destructive) {
                                Task {
                                    await api.regenerateCredentials()
                                    showToast("Key regenerated")
                                }
                            } label: {
                                Label("Regenerate API key", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                    }

                    // Connection
                    Section("Connection") {
                        LabeledContent("API") {
                            Text(api.baseURL)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        LabeledContent("User ID") {
                            Text(api.userId.isEmpty ? "—" : api.userId)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    // Live Activity status
                    Section("Live Activity") {
                        HStack {
                            Circle()
                                .fill(lam.isActive ? Color.green : Color.gray)
                                .frame(width: 10, height: 10)
                            Text(lam.isActive ? "Active" : "Inactive")
                                .foregroundStyle(lam.isActive ? .primary : .secondary)
                        }
                        if let state = lam.lastState {
                            LabeledContent("Title", value: state.title)
                            LabeledContent("Body", value: state.body)
                        }
                    }

                    // Controls
                    Section("Controls") {
                        if !lam.isActive {
                            Button {
                                Task { await lam.startActivity() }
                            } label: {
                                Label("Start Live Activity", systemImage: "play.fill")
                            }
                        } else {
                            Button(role: .destructive) {
                                Task { await lam.stopActivity() }
                            } label: {
                                Label("Stop Live Activity", systemImage: "stop.fill")
                            }
                            Button {
                                let state = mockStates[mockIndex % mockStates.count]
                                mockIndex += 1
                                Task { await lam.updateActivity(state: state) }
                            } label: {
                                Label("Simulate Push Update", systemImage: "arrow.clockwise")
                            }
                        }
                    }

                    // Push tokens
                    Section("Push Tokens") {
                        tokenRow(label: "Device Token", value: lam.deviceToken)
                        tokenRow(label: "Activity Token", value: lam.activityPushToken)
                        if #available(iOS 17.2, *) {
                            tokenRow(label: "Push-to-Start Token", value: lam.pushToStartToken)
                        }
                    }
                }
            }
            .navigationTitle("Feedling")
            .overlay(alignment: .bottom) {
                if let msg = showCopiedToast {
                    Text(msg)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.opacity)
                }
            }
        }
    }

    private func showToast(_ message: String) {
        withAnimation { showCopiedToast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { showCopiedToast = nil }
        }
    }

    @ViewBuilder
    private func tokenRow(label: String, value: String?) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    Text(value.prefix(24) + "…")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.primary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = value
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.cyan)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        } else {
            LabeledContent(label, value: "—")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Broadcast Picker

struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width - 32, height: 52))
        picker.preferredExtension = "com.feedling.mcp.broadcast"
        picker.showsMicrophoneButton = false
        picker.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        for subview in picker.subviews {
            if let button = subview as? UIButton {
                button.imageView?.tintColor = .white
                button.backgroundColor = .clear
            }
        }
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width - 32, height: 52)
    }
}
