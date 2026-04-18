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
                    // Connection
                    Section("Connection") {
                        LabeledContent("API") {
                            Text(FeedlingAPI.baseURL)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        LabeledContent("Pairing Code") {
                            Text("—")
                                .foregroundStyle(.secondary)
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
