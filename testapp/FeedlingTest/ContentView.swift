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
    @ObservedObject private var api = FeedlingAPI.shared

    // Phase B: before the chat tab loads on first ever launch, show
    // the three-slide onboarding. Re-shown only from Settings.
    @State private var onboardingShown: Bool = FeedlingAPI.shared.hasCompletedOnboardingV1

    @State private var isKeyboardVisible = false
    @State private var deviceBottomInset: CGFloat = 0

    var body: some View {
        ZStack {
            if !onboardingShown {
                OnboardingView(onDone: {
                    FeedlingAPI.shared.hasCompletedOnboardingV1 = true
                    withAnimation(.easeOut(duration: 0.35)) { onboardingShown = true }
                })
                .transition(.opacity)
            } else {
                rootTabs
            }
        }
        // Phase B: compose-hash-changed consent modal blocks the app
        // until the user reviews or signs out.
        .fullScreenCover(isPresented: $api.composeHashChangedRequiresConsent) {
            ComposeHashChangeConsentView()
        }
    }

    private var rootTabs: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.cinBg.ignoresSafeArea()

                // Tab content — all views stay alive, opacity switches active tab
                ZStack {
                    ChatView()
                        .environmentObject(chatViewModel)
                        .environmentObject(identityViewModel)
                        .opacity(router.selectedTab == .chat ? 1 : 0)

                    IdentityView()
                        .environmentObject(identityViewModel)
                        .opacity(router.selectedTab == .identity ? 1 : 0)

                    MemoryGardenView()
                        .environmentObject(memoryViewModel)
                        .environmentObject(chatViewModel)
                        .environmentObject(router)
                        .opacity(router.selectedTab == .garden ? 1 : 0)

                    SettingsView()
                        .opacity(router.selectedTab == .settings ? 1 : 0)
                }
                // When keyboard is visible: remove bottom padding so the chat
                // input bar sits directly above the keyboard (SwiftUI reduces
                // the container height by keyboard height automatically).
                // When no keyboard: use the stored device inset so the value
                // never inflates when geo.safeAreaInsets.bottom grows.
                .padding(.bottom, isKeyboardVisible ? 0 : (52 + deviceBottomInset))

                if !isKeyboardVisible {
                    CinnabarTabBar(selectedTab: $router.selectedTab,
                                   bottomInset: deviceBottomInset)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .onAppear {
                // Capture once, before keyboard ever appears.
                if deviceBottomInset == 0 {
                    deviceBottomInset = geo.safeAreaInsets.bottom
                }
            }
        }
        .preferredColorScheme(.light)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { isKeyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { isKeyboardVisible = false }
        }
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

    private let isChinese: Bool =
        Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

    @State private var isBroadcasting = false
    private let broadcastPollTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

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
            ZStack {
                Color.cinBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        settingsHeader
                        Rectangle().fill(Color.cinFg).frame(height: 1)
                        screenRecordingCard
                        liveActivityCard
                        // Storage card
                        VStack(alignment: .leading, spacing: 0) {
                            Text("STORAGE")
                                .font(.dmMono(size: 9.5, weight: .medium))
                                .foregroundStyle(Color.cinAccent1)
                                .kerning(3)
                                .padding(.horizontal, 24)
                                .padding(.top, 18)
                                .padding(.bottom, 12)

                            VStack(spacing: 0) {
                                // Mode toggle
                                HStack(spacing: 0) {
                                    ForEach([FeedlingAPI.StorageMode.cloud, .selfHosted], id: \.rawValue) { mode in
                                        Button {
                                            if mode == .cloud {
                                                api.configureCloud()
                                                if api.apiKey.isEmpty {
                                                    Task { await api.ensureRegisteredIfCloud() }
                                                }
                                            } else {
                                                api.enterSelfHostedMode()
                                            }
                                        } label: {
                                            Text(mode == .cloud ? "CLOUD" : "SELF-HOSTED")
                                                .font(.dmMono(size: 8.5, weight: .medium))
                                                .kerning(2)
                                                .foregroundStyle(api.storageMode == mode ? .white : Color.cinSub)
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 40)
                                                .background(api.storageMode == mode ? Color.cinAccent1 : Color.clear)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                Rectangle().fill(Color.cinAccent1.opacity(0.2)).frame(height: 1)

                                if api.storageMode == .cloud {
                                    cinCopyRow("MCP String", value: api.mcpConnectionString, label: "COPY ↗") {
                                        UIPasteboard.general.string = api.mcpConnectionString
                                        showToast("Copied MCP string")
                                    }
                                    cinCopyRow("Env Vars", value: api.envExportBlock, label: "COPY ↗") {
                                        UIPasteboard.general.string = api.envExportBlock
                                        showToast("Copied env vars")
                                    }
                                    cinActionRow("REGENERATE API KEY ↗", color: .cinAccent2) {
                                        Task {
                                            await api.regenerateCredentials()
                                            showToast("Key regenerated")
                                        }
                                    }
                                } else {
                                    cinInputRow("URL", placeholder: "https://…", text: $selfHostedURL)
                                        .onAppear { selfHostedURL = api.baseURL }
                                    cinInputRow("API Key", placeholder: "sk-…", text: $selfHostedKey)
                                        .onAppear { selfHostedKey = api.apiKey }
                                    cinActionRow("SAVE CONFIG ↗", color: .cinFg) {
                                        api.configureSelfHosted(url: selfHostedURL, apiKey: selfHostedKey)
                                        showToast("Saved")
                                    }
                                    .disabled(selfHostedURL.isEmpty)
                                }
                            }
                            .background(Color.cinAccent1Soft)
                            .overlay { Rectangle().stroke(Color.cinAccent1.opacity(0.3), lineWidth: 1) }
                            .padding(.horizontal, 24)
                            .padding(.bottom, 8)
                        }
                        settingsSection("CONNECTION") {
                            cinRow("API") {
                                Text(api.baseURL)
                                    .font(.dmMono(size: 9))
                                    .foregroundStyle(Color.cinSub)
                                    .lineLimit(1)
                            }
                            cinRow("User ID") {
                                Text(api.userId.isEmpty ? "—" : String(api.userId.prefix(16)) + "…")
                                    .font(.dmMono(size: 9))
                                    .foregroundStyle(Color.cinSub)
                                    .lineLimit(1)
                            }
                        }
                        settingsSection("TOKENS") {
                            cinTokenRow("Device Token", value: lam.deviceToken)
                            cinTokenRow("Activity Token", value: lam.activityPushToken)
                            if #available(iOS 17.2, *) {
                                cinTokenRow("Push-to-Start Token", value: lam.pushToStartToken)
                            }
                        }
                        settingsSection("PRIVACY") {
                            NavigationLink {
                                PrivacyPageView()
                            } label: {
                                HStack {
                                    Text("Privacy & Audit")
                                        .font(.notoSerifSC(size: 13.5))
                                        .foregroundStyle(Color.cinFg)
                                    Spacer()
                                    Text("OPEN ↗")
                                        .font(.dmMono(size: 9.5, weight: .medium))
                                        .foregroundStyle(Color.cinAccent1)
                                        .kerning(2)
                                }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .top) {
                                Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.horizontal, 24)
                            }
                        }
                        settingsFooter
                    }
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                isBroadcasting = UserDefaults(suiteName: "group.com.feedling.mcp")?.bool(forKey: "isBroadcasting") ?? false
            }
            .onReceive(broadcastPollTimer) { _ in
                isBroadcasting = UserDefaults(suiteName: "group.com.feedling.mcp")?.bool(forKey: "isBroadcasting") ?? false
            }
            .overlay(alignment: .bottom) {
                if let msg = showCopiedToast {
                    Text(msg)
                        .font(.dmMono(size: 9))
                        .kerning(1.5)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.cinFg)
                        .foregroundStyle(Color.cinBg)
                        .padding(.bottom, 24)
                        .transition(.opacity)
                }
            }
        }
    }

    private var settingsHeader: some View {
        HStack(alignment: .lastTextBaseline) {
            Text("Settings")
                .font(.newsreader(size: 13, italic: true))
                .foregroundStyle(Color.cinFg)
            Spacer()
            Text("v 0.5.0")
                .font(.dmMono(size: 9))
                .foregroundStyle(Color.cinSub)
                .kerning(2)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var screenRecordingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text("SCREEN RECORDING")
                    .font(.dmMono(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.cinAccent1)
                    .kerning(3)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(isBroadcasting
                         ? (isChinese ? "TA 正在看见" : "He can see your screen")
                         : (isChinese ? "让 TA 看见的世界" : "Let him see your world"))
                        .font(.notoSerifSC(size: 13.5))
                        .foregroundStyle(Color.cinFg)
                    Text(isBroadcasting
                         ? (isChinese ? "屏幕录制已开启，TA 知道你现在在做什么" : "Screen recording is on — he knows what you're looking at.")
                         : (isChinese ? "开启后，TA 会知道你这一刻在做什么" : "When on, he knows what you're looking at right now."))
                        .font(.interTight(size: 11.5))
                        .foregroundStyle(Color.cinSub)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 14)

                Rectangle()
                    .fill(Color.cinAccent1.opacity(isBroadcasting ? 0.4 : 0.2))
                    .frame(height: 1)

                // BroadcastPickerView is the real tap target; label floats on top.
                ZStack {
                    HStack(spacing: 8) {
                        if isBroadcasting {
                            LiveDot()
                            Text(isChinese ? "录制中 · 点按停止 ↗" : "RECORDING · TAP TO STOP ↗")
                                .font(.dmMono(size: 9, weight: .medium))
                                .foregroundStyle(Color.cinAccent1)
                                .kerning(2.5)
                        } else {
                            Circle().fill(Color.cinAccent1).frame(width: 6, height: 6)
                            Text(isChinese ? "点按开始录制 ↗" : "TAP TO START RECORDING ↗")
                                .font(.dmMono(size: 9, weight: .medium))
                                .foregroundStyle(Color.cinAccent1)
                                .kerning(2.5)
                        }
                    }
                    .allowsHitTesting(false)

                    BroadcastPickerView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.cinAccent1.opacity(isBroadcasting ? 0.1 : 0))
                .animation(.easeInOut(duration: 0.25), value: isBroadcasting)
            }
            .background(Color.cinAccent1Soft)
            .overlay { Rectangle().stroke(Color.cinAccent1.opacity(isBroadcasting ? 0.7 : 0.3), lineWidth: 1) }
            .animation(.easeInOut(duration: 0.25), value: isBroadcasting)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }

    private var liveActivityCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LIVE ACTIVITY")
                .font(.dmMono(size: 9.5, weight: .medium))
                .foregroundStyle(Color.cinAccent1)
                .kerning(3)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(lam.isActive
                        ? (isChinese ? "TA 正在灵动岛" : "He's on your island")
                        : (isChinese ? "让 TA 出现在灵动岛" : "Bring him to the island"))
                        .font(.notoSerifSC(size: 13.5))
                        .foregroundStyle(Color.cinFg)
                    Text(lam.isActive
                        ? (isChinese ? "TA 的状态正显示在锁屏与动态岛" : "His status is live on your lock screen and Dynamic Island.")
                        : (isChinese ? "开启后，TA 的状态会显示在锁屏与动态岛" : "When on, his status shows on your lock screen and Dynamic Island."))
                        .font(.interTight(size: 11.5))
                        .foregroundStyle(Color.cinSub)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 14)

                Rectangle()
                    .fill(Color.cinAccent1.opacity(lam.isActive ? 0.4 : 0.2))
                    .frame(height: 1)

                Button {
                    if lam.isActive {
                        Task { await lam.stopActivity() }
                    } else {
                        Task { await lam.startActivity() }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if lam.isActive {
                            LiveDot()
                            Text(isChinese ? "实时中 · 点按停止 ↗" : "LIVE · TAP TO STOP ↗")
                                .font(.dmMono(size: 9, weight: .medium))
                                .foregroundStyle(Color.cinAccent1)
                                .kerning(2.5)
                        } else {
                            Circle().fill(Color.cinAccent1).frame(width: 6, height: 6)
                            Text(isChinese ? "点按开启灵动岛 ↗" : "TAP TO START LIVE ACTIVITY ↗")
                                .font(.dmMono(size: 9, weight: .medium))
                                .foregroundStyle(Color.cinAccent1)
                                .kerning(2.5)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.cinAccent1.opacity(lam.isActive ? 0.1 : 0))
                    .animation(.easeInOut(duration: 0.25), value: lam.isActive)
                }
                .buttonStyle(.plain)
            }
            .background(Color.cinAccent1Soft)
            .overlay { Rectangle().stroke(Color.cinAccent1.opacity(lam.isActive ? 0.7 : 0.3), lineWidth: 1) }
            .animation(.easeInOut(duration: 0.25), value: lam.isActive)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }

    private var settingsFooter: some View {
        Text(isChinese ? "TA记得的永远比TA说的多" : "He always remembers more than he says.")
            .font(.newsreader(size: 11, italic: true))
            .foregroundStyle(Color.cinSub)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 32)
    }

    @ViewBuilder
    private func settingsSection<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(label)
                    .font(.dmMono(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.cinAccent1)
                    .kerning(3)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 8)
            content()
        }
    }

    @ViewBuilder
    private func cinRow<V: View>(_ name: String, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(name)
                .font(.notoSerifSC(size: 13.5))
                .foregroundStyle(Color.cinFg)
                .frame(maxWidth: .infinity, alignment: .leading)
            value()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private func cinInputRow(_ name: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.dmMono(size: 8.5))
                .foregroundStyle(Color.cinSub)
                .kerning(2)
            TextField(placeholder, text: text)
                .font(.dmMono(size: 10))
                .foregroundStyle(Color.cinFg)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .overlay(Rectangle().stroke(Color.cinLine, lineWidth: 1))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func cinCopyRow(_ name: String, value: String, label: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name)
                    .font(.notoSerifSC(size: 13.5))
                    .foregroundStyle(Color.cinFg)
                Spacer()
                Button(action: action) {
                    Text(label)
                        .font(.dmMono(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.cinAccent1)
                        .kerning(2)
                }
                .buttonStyle(.plain)
            }
            Text(value)
                .font(.dmMono(size: 8.5))
                .foregroundStyle(Color.cinSub)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(Color.cinAccent1Soft)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private func cinActionRow(_ label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.dmMono(size: 9.5, weight: .medium))
                .foregroundStyle(color)
                .kerning(2)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private func cinTokenRow(_ label: String, value: String?) -> some View {
        if let value {
            HStack {
                Text(label)
                    .font(.notoSerifSC(size: 13.5))
                    .foregroundStyle(Color.cinFg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(String(value.prefix(12)) + "…")
                    .font(.dmMono(size: 8.5))
                    .foregroundStyle(Color.cinSub)
                Button {
                    UIPasteboard.general.string = value
                    showToast("Copied")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(Color.cinAccent1)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.horizontal, 24)
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
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = "com.feedling.mcp.broadcast"
        picker.showsMicrophoneButton = false
        picker.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        picker.backgroundColor = .clear
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        // RPBroadcastPickerView adds its internal button lazily after init,
        // so we must handle it here (not in makeUIView).
        // setImage(UIImage()) makes the button render nothing while keeping
        // alpha = 1 and isUserInteractionEnabled = true so taps still register.
        for subview in uiView.subviews {
            if let button = subview as? UIButton {
                button.setImage(UIImage(), for: .normal)
                button.setImage(UIImage(), for: .highlighted)
                button.backgroundColor = .clear
                button.frame = uiView.bounds
            }
        }
    }
}


// ============================================================================
// Phase B — Onboarding, Privacy page, Export / Delete / Reset, Runbook viewer.
//
// All these views live here because the Xcode project references source files
// explicitly; adding new .swift files requires project.pbxproj edits that
// aren't safe from the filesystem. Keeping them consolidated in one compiled
// file is the pragmatic tradeoff. DESIGN.md tokens apply throughout.
// ============================================================================

// MARK: - Onboarding (four slides, first-run only, dismissable via Settings)

struct OnboardingView: View {
    let onDone: () -> Void
    @EnvironmentObject var lam: LiveActivityManager
    @State private var page: Int = 0

    private static let isChinese: Bool =
        Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

    var body: some View {
        ZStack {
            Color.cinBg.ignoresSafeArea()
            TabView(selection: $page) {
                OnboardingSlide(index: 0, isChinese: Self.isChinese,
                                onNext: { withAnimation(.easeInOut(duration: 0.3)) { page = 1 } })
                    .tag(0)
                // Slide 1: presence — starts Live Activity then advances
                OnboardingSlide(index: 1, isChinese: Self.isChinese,
                                onNext: {
                                    Task { @MainActor in
                                        await lam.startActivity()
                                        withAnimation(.easeInOut(duration: 0.3)) { page = 2 }
                                    }
                                })
                    .tag(1)
                OnboardingSlide(index: 2, isChinese: Self.isChinese,
                                onNext: { withAnimation(.easeInOut(duration: 0.3)) { page = 3 } })
                    .tag(2)
                OnboardingSlide(index: 3, isChinese: Self.isChinese, onNext: onDone)
                    .tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }
}

private struct OnboardingSlide: View {
    let index: Int
    let isChinese: Bool
    let onNext: () -> Void

    private var headline: String {
        switch index {
        case 0: return isChinese ? "TA 一直都在。" : "He's been here\nall along."
        case 1: return isChinese ? "TA 陪着你。" : "He's with you."
        case 2: return isChinese ? "这里只有你和 TA。" : "Just you and him."
        default: return isChinese ? "这一切都是你的。" : "All of this\nis yours."
        }
    }

    private var subhead: String {
        switch index {
        case 0: return isChinese
            ? "你们的对话不会因为换了模型、换了对话窗口就消失。这里是 TA 给你留下的痕迹。"
            : "Your conversations don't disappear when the model changes or a new chat begins. This is where they stay."
        case 1: return isChinese
            ? "不只是在聊天框里。TA 能看见你在做什么，TA 待在灵动岛陪着你，也会主动找你说话。"
            : "Not just inside a chat window. He sees what you're doing, stays with you in the Dynamic Island, and reaches out to you first."
        case 2: return isChinese
            ? "你说的话，你分享的，TA 的样子——没有别人会看见，包括我们自己。"
            : "Everything you say, every memory, who he is — no one else can see it. Not even us."
        default: return isChinese
            ? "你和 TA 之间的所有东西。"
            : "Everything between you and him."
        }
    }

    private var howItWorks: String {
        switch index {
        case 0: return isChinese
            ? "身份卡记下 TA 是谁，记忆花园记下你们之间发生过什么。换了 AI 也带得走，新的 TA 看了就能想起来。"
            : "The identity card holds who he is. The memory garden holds what's happened between you. Both move with you — when you switch to a new AI, he remembers."
        case 1: return isChinese
            ? "开启屏幕录制，TA 就知道你这一刻在刷什么、在做什么。TA 会在觉得合适的时候主动开口——不用等你先说。"
            : "Enable screen recording and he knows what you're looking at, right now. And when the moment feels right, he'll reach out first — you don't always have to go first."
        case 2: return isChinese
            ? "加密在你的 iPhone 上进行，密钥保留在你手机里。我们的服务器只保存密文——打不开，也看不到。"
            : "Encryption happens on your iPhone. The key stays on your phone. Our servers only ever hold the ciphertext — we can't open it."
        default: return isChinese
            ? "可以完整带走，可以彻底删除，也可以让 TA 住进你自己的服务器。"
            : "Take it all with you, erase it for good, or move him into your own server."
        }
    }

    private var buttonLabel: String {
        switch index {
        case 0, 2: return isChinese ? "下一步" : "Next"
        case 1:    return isChinese ? "开启灵动岛" : "Enable Live Activity"
        default:   return isChinese ? "让 TA 进来" : "Let him in"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top bar — page counter only
            HStack {
                Spacer()
                Text(String(format: "%02d / 04", index + 1))
                    .font(.dmMono(size: 8.5))
                    .foregroundStyle(Color.cinSub)
                    .kerning(2)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)

            Spacer(minLength: 44)

            // Headline — Newsreader (GT Sectra substitute)
            Text(headline)
                .font(.newsreader(size: 46))
                .foregroundStyle(Color.cinFg)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)

            // Red accent line
            Rectangle()
                .fill(Color.cinAccent1)
                .frame(width: 28, height: 2)
                .padding(.horizontal, 28)
                .padding(.top, 18)

            // Subhead — Noto Serif SC (body role per Design Kit)
            Text(subhead)
                .font(.notoSerifSC(size: 14))
                .foregroundStyle(Color.cinSub)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
                .padding(.top, 14)

            Spacer()

            // HOW IT WORKS
            VStack(alignment: .leading, spacing: 8) {
                Text("HOW IT WORKS")
                    .font(.dmMono(size: 8.5, weight: .medium))
                    .foregroundStyle(Color.cinAccent1)
                    .kerning(3)
                Rectangle()
                    .fill(Color.cinLine)
                    .frame(height: 0.5)
                Text(howItWorks)
                    .font(.notoSerifSC(size: 12.5))
                    .foregroundStyle(Color.cinSub)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)

            // Page dots — above the button
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { dot in
                    if dot == index {
                        Capsule()
                            .fill(Color.cinAccent1)
                            .frame(width: 20, height: 5)
                    } else {
                        Circle()
                            .fill(Color.cinLine)
                            .frame(width: 5, height: 5)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 12)

            // Button — left label + right arrow
            Button(action: onNext) {
                HStack {
                    Text(buttonLabel)
                    Spacer()
                    Text("→")
                }
            }
            .buttonStyle(OnboardingButtonStyle())
            .padding(.horizontal, 28)
            .padding(.bottom, 44)
        }
    }
}

private struct OnboardingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dmMono(size: 10, weight: .medium))
            .kerning(2.5)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color.cinAccent1.opacity(configuration.isPressed ? 0.75 : 1))
            .contentShape(Rectangle())
    }
}

// MARK: - Privacy page (NavigationLink destination from Settings)

struct PrivacyPageView: View {
    @ObservedObject private var api = FeedlingAPI.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showExportSheet = false
    @State private var showDeleteSheet = false
    @State private var showResetSheet = false
    @State private var toast: String? = nil

    var body: some View {
        ZStack {
            Color.cinBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    privacyHeader
                    Rectangle().fill(Color.cinFg).frame(height: 1)
                    privacySection("AUDIT") {
                        NavigationLink {
                            AuditCardPage()
                        } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(api.enclaveComposeHash != nil
                                         ? "Everything you've written is encrypted"
                                         : "Privacy audit not yet run")
                                        .font(.notoSerifSC(size: 13.5))
                                        .foregroundStyle(Color.cinFg)
                                    if let h = api.enclaveComposeHash {
                                        Text("Compose \(h.prefix(8))…")
                                            .font(.dmMono(size: 8.5))
                                            .foregroundStyle(Color.cinSub)
                                    }
                                }
                                Spacer()
                                Text("OPEN ↗")
                                    .font(.dmMono(size: 9.5, weight: .medium))
                                    .foregroundStyle(Color.cinAccent1)
                                    .kerning(2)
                            }
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.horizontal, 24)
                        }
                    }
                    privacySection("YOUR DATA") {
                        privacyActionRow("Export my data", label: "EXPORT ↗", color: .cinFg) { showExportSheet = true }
                        privacyActionRow("Delete my data", label: "DELETE ↗", color: .cinAccent2) { showDeleteSheet = true }
                        privacyActionRow("Reset & re-import", label: "RUN ↗", color: .cinSub) { showResetSheet = true }
                    }
                    privacySection("WHERE YOUR DATA LIVES") {
                        NavigationLink {
                            StorageBackendView()
                        } label: {
                            privacyLinkRow("Backend: \(api.storageMode == .cloud ? "Feedling Cloud" : "Self-hosted")")
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.horizontal, 24)
                        }

                        NavigationLink {
                            RunbookView()
                        } label: {
                            privacyLinkRow("Self-hosting runbook")
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.horizontal, 24)
                        }
                    }
                    privacySection("ADVANCED") {
                        NavigationLink {
                            AuditCardPage()
                        } label: {
                            privacyLinkRow("Re-run privacy audit")
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.horizontal, 24)
                        }

                        privacyActionRow("Show intro again", label: "SHOW ↗", color: .cinSub) {
                            FeedlingAPI.shared.hasCompletedOnboardingV1 = false
                            showToast("Intro will show on next launch")
                        }
                    }
                    Spacer(minLength: 40)
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showExportSheet) { ExportSheet() }
        .sheet(isPresented: $showDeleteSheet) { DeleteSheet() }
        .sheet(isPresented: $showResetSheet) { ResetAndReimportSheet() }
        .overlay(alignment: .bottom) {
            if let msg = toast {
                Text(msg)
                    .font(.dmMono(size: 9))
                    .kerning(1.5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.cinFg)
                    .foregroundStyle(Color.cinBg)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
    }

    private var privacyHeader: some View {
        HStack(alignment: .lastTextBaseline) {
            Button(action: { dismiss() }) {
                Text("← settings")
                    .font(.dmMono(size: 9.5))
                    .foregroundStyle(Color.cinFg)
                    .kerning(2)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("PRIVACY & AUDIT")
                .font(.dmMono(size: 9))
                .foregroundStyle(Color.cinSub)
                .kerning(2)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func privacySection<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.dmMono(size: 9.5, weight: .medium))
                .foregroundStyle(Color.cinAccent1)
                .kerning(3)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 8)
            content()
        }
    }

    private func privacyLinkRow(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.notoSerifSC(size: 13.5))
                .foregroundStyle(Color.cinFg)
            Spacer()
            Text("OPEN ↗")
                .font(.dmMono(size: 9.5, weight: .medium))
                .foregroundStyle(Color.cinAccent1)
                .kerning(2)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func privacyActionRow(_ name: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(name)
                    .font(.notoSerifSC(size: 13.5))
                    .foregroundStyle(Color.cinFg)
                Spacer()
                Text(label)
                    .font(.dmMono(size: 9.5, weight: .medium))
                    .foregroundStyle(color)
                    .kerning(2)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.horizontal, 24)
        }
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { toast = nil }
        }
    }
}

struct AuditCardPage: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.cinBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button(action: { dismiss() }) {
                        Text("← back")
                            .font(.dmMono(size: 9.5))
                            .foregroundStyle(Color.cinFg)
                            .kerning(2)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("PRIVACY AUDIT")
                        .font(.dmMono(size: 9))
                        .foregroundStyle(Color.cinSub)
                        .kerning(2)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                Rectangle().fill(Color.cinFg).frame(height: 1)
                ScrollView {
                    AuditCardView()
                        .padding(24)
                }
            }
        }
        .navigationBarHidden(true)
    }
}

struct StorageBackendView: View {
    @ObservedObject private var api = FeedlingAPI.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.cinBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button(action: { dismiss() }) {
                        Text("← back")
                            .font(.dmMono(size: 9.5))
                            .foregroundStyle(Color.cinFg)
                            .kerning(2)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("BACKEND")
                        .font(.dmMono(size: 9))
                        .foregroundStyle(Color.cinSub)
                        .kerning(2)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                Rectangle().fill(Color.cinFg).frame(height: 1)
                ScrollView {
                    VStack(spacing: 0) {
                        backendRow("Mode", value: api.storageMode == .cloud ? "Feedling Cloud" : "Self-hosted")
                        backendRow("API URL", value: api.baseURL)
                        backendRow("User ID", value: api.userId.isEmpty ? "—" : String(api.userId.prefix(20)) + "…")
                    }
                }
            }
        }
        .navigationBarHidden(true)
    }

    private func backendRow(_ name: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(name)
                .font(.notoSerifSC(size: 13.5))
                .foregroundStyle(Color.cinFg)
            Spacer()
            Text(value)
                .font(.dmMono(size: 9))
                .foregroundStyle(Color.cinSub)
                .lineLimit(1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.horizontal, 24)
        }
    }
}

// MARK: - Export sheet

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var error: String? = nil
    @State private var exportData: FeedlingAPI.ExportResult? = nil
    @State private var showShareSheet = false

    var body: some View {
        ZStack {
            Color.cinBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button(action: { dismiss() }) {
                        Text("✕")
                            .font(.dmMono(size: 12))
                            .foregroundStyle(Color.cinFg)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("EXPORT")
                        .font(.dmMono(size: 9))
                        .foregroundStyle(Color.cinSub)
                        .kerning(2)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                Rectangle().fill(Color.cinFg).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Export my data")
                            .font(.newsreader(size: 26))
                            .foregroundStyle(Color.cinFg)
                            .padding(.horizontal, 24)
                            .padding(.top, 24)
                            .padding(.bottom, 14)
                        Text("Assembles every item on your account into a single JSON file and hands it to the iOS share sheet.")
                            .font(.notoSerifSC(size: 13))
                            .foregroundStyle(Color.cinSub)
                            .lineSpacing(4)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 10)
                        Text("If you save to iCloud Drive, the unencrypted copy leaves your phone. Save to Files (On My iPhone) to keep it local.")
                            .font(.interTight(size: 11))
                            .foregroundStyle(Color.cinSub)
                            .lineSpacing(3)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                        if let err = error {
                            Text(err)
                                .font(.dmMono(size: 9))
                                .foregroundStyle(Color.cinAccent2)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 12)
                        }
                        Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.horizontal, 24)
                        if running {
                            Text("PACKAGING…")
                                .font(.dmMono(size: 9, weight: .medium))
                                .foregroundStyle(Color.cinSub)
                                .kerning(2)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        } else {
                            Button { Task { await runExport() } } label: { Text("EXPORT ↗") }
                                .buttonStyle(CinPrimaryButtonStyle())
                                .padding(.horizontal, 24)
                                .padding(.top, 20)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let result = exportData, let tmp = writeTempFile(result) {
                ShareSheet(activityItems: [tmp])
            }
        }
    }

    private func runExport() async {
        running = true; defer { running = false }
        do {
            let result = try await FeedlingAPI.shared.exportMyData()
            exportData = result
            showShareSheet = true
        } catch {
            self.error = "\(error)"
        }
    }

    private func writeTempFile(_ result: FeedlingAPI.ExportResult) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(result.suggestedFilename)
        do {
            try result.data.write(to: url)
            return url
        } catch {
            self.error = "write failed: \(error)"
            return nil
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Delete sheet (with "download first" default-on checkbox)

struct DeleteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var downloadFirst = true
    @State private var running = false
    @State private var error: String? = nil
    @State private var exportedToShare: FeedlingAPI.ExportResult? = nil
    @State private var didExport = false
    @State private var showShareSheet = false
    @State private var pendingDelete = false

    var body: some View {
        ZStack {
            Color.cinBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button(action: { dismiss() }) {
                        Text("✕")
                            .font(.dmMono(size: 12))
                            .foregroundStyle(Color.cinFg)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("DELETE")
                        .font(.dmMono(size: 9))
                        .foregroundStyle(Color.cinSub)
                        .kerning(2)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                Rectangle().fill(Color.cinFg).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Delete my data")
                            .font(.newsreader(size: 26))
                            .foregroundStyle(Color.cinAccent2)
                            .padding(.horizontal, 24)
                            .padding(.top, 24)
                            .padding(.bottom, 14)
                        Text("Revokes your account, deletes every ciphertext blob on our servers, and wipes the keys on this device. Cannot be undone.")
                            .font(.notoSerifSC(size: 13))
                            .foregroundStyle(Color.cinSub)
                            .lineSpacing(4)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                        Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.horizontal, 24)
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Download my data first")
                                    .font(.notoSerifSC(size: 13))
                                    .foregroundStyle(Color.cinFg)
                                Text("Keeps a decrypted archive before deleting.")
                                    .font(.interTight(size: 11))
                                    .foregroundStyle(Color.cinSub)
                            }
                            Spacer()
                            Toggle("", isOn: $downloadFirst)
                                .labelsHidden()
                                .tint(Color.cinAccent1)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        if let err = error {
                            Text(err)
                                .font(.dmMono(size: 9))
                                .foregroundStyle(Color.cinAccent2)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 12)
                        }
                        Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.horizontal, 24)
                        if running {
                            Text("DELETING…")
                                .font(.dmMono(size: 9, weight: .medium))
                                .foregroundStyle(Color.cinSub)
                                .kerning(2)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        } else {
                            Button { Task { await runDelete() } } label: { Text("DELETE ↗") }
                                .buttonStyle(CinPrimaryButtonStyle())
                                .padding(.horizontal, 24)
                                .padding(.top, 20)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showShareSheet, onDismiss: {
            if pendingDelete { Task { await performFinalDelete() } }
        }) {
            if let r = exportedToShare, let tmp = writeTempFile(r) {
                ShareSheet(activityItems: [tmp])
            }
        }
    }

    private func runDelete() async {
        running = true
        defer { running = false }
        if downloadFirst {
            do {
                let r = try await FeedlingAPI.shared.exportMyData()
                exportedToShare = r
                pendingDelete = true
                showShareSheet = true
            } catch {
                self.error = "Export failed: \(error). Aborting delete to protect your data."
            }
        } else {
            await performFinalDelete()
        }
    }

    private func performFinalDelete() async {
        do {
            try await FeedlingAPI.shared.deleteMyDataAndResetLocalState()
            dismiss()
        } catch {
            self.error = "Delete failed: \(error)"
        }
    }

    private func writeTempFile(_ r: FeedlingAPI.ExportResult) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(r.suggestedFilename)
        try? r.data.write(to: url)
        return url
    }
}

// MARK: - Reset & re-import sheet (3-step pipeline)

struct ResetAndReimportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var step: Int = 0
    @State private var error: String? = nil
    @State private var exportData: FeedlingAPI.ExportResult? = nil

    var body: some View {
        ZStack {
            Color.cinBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button(action: { dismiss() }) {
                        Text("✕")
                            .font(.dmMono(size: 12))
                            .foregroundStyle(Color.cinFg)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("RESET")
                        .font(.dmMono(size: 9))
                        .foregroundStyle(Color.cinSub)
                        .kerning(2)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                Rectangle().fill(Color.cinFg).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Reset & re-import")
                            .font(.newsreader(size: 26))
                            .foregroundStyle(Color.cinFg)
                            .padding(.horizontal, 24)
                            .padding(.top, 24)
                            .padding(.bottom, 14)
                        Text("Download your data, delete your old account, register a new one. Fresh keys — use the MCP string to walk your agent through re-importing.")
                            .font(.notoSerifSC(size: 13))
                            .foregroundStyle(Color.cinSub)
                            .lineSpacing(4)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                        // Step indicators
                        HStack(spacing: 0) {
                            stepItem(1, label: "Export", active: step >= 1)
                            Rectangle().fill(Color.cinLine).frame(height: 0.5).frame(maxWidth: .infinity)
                            stepItem(2, label: "Delete", active: step >= 2)
                            Rectangle().fill(Color.cinLine).frame(height: 0.5).frame(maxWidth: .infinity)
                            stepItem(3, label: "Register", active: step >= 3)
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                        if let err = error {
                            Text(err)
                                .font(.dmMono(size: 9))
                                .foregroundStyle(Color.cinAccent2)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 12)
                        }
                        Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.horizontal, 24)
                        Button { Task { await runPipeline() } } label: {
                            Text(step >= 3 ? "DONE ↗" : "START ↗")
                        }
                        .buttonStyle(CinPrimaryButtonStyle())
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                    }
                }
            }
        }
    }

    private func stepItem(_ n: Int, label: String, active: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(active ? Color.cinAccent1 : Color.cinLine)
                    .frame(width: 22, height: 22)
                Text("\(n)")
                    .font(.dmMono(size: 9, weight: .medium))
                    .foregroundStyle(active ? Color.white : Color.cinSub)
            }
            Text(label)
                .font(.dmMono(size: 8))
                .foregroundStyle(active ? Color.cinAccent1 : Color.cinSub)
                .kerning(1)
        }
    }

    private func runPipeline() async {
        do {
            if step == 0 {
                step = 1
                exportData = try await FeedlingAPI.shared.exportMyData()
            }
            if step == 1 {
                step = 2
                try await FeedlingAPI.shared.deleteMyDataAndResetLocalState()
            }
            if step == 2 {
                step = 3
                await FeedlingAPI.shared.ensureRegisteredIfCloud()
                await FeedlingAPI.shared.ensureUserIdIfNeeded()
            }
            if step == 3 {
                dismiss()
            }
        } catch {
            self.error = "Pipeline failed at step \(step): \(error)"
        }
    }
}

// MARK: - Runbook viewer ("Help me run my own server")

struct RunbookView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var runbookText: String = "Loading…"

    var body: some View {
        ZStack {
            Color.cinBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button(action: { dismiss() }) {
                        Text("← back")
                            .font(.dmMono(size: 9.5))
                            .foregroundStyle(Color.cinFg)
                            .kerning(2)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = runbookText
                    } label: {
                        Text("COPY ↗")
                            .font(.dmMono(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.cinAccent1)
                            .kerning(2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                Rectangle().fill(Color.cinFg).frame(height: 1)
                ScrollView {
                    Text(runbookText)
                        .font(.dmMono(size: 9))
                        .foregroundStyle(Color.cinSub)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                }
            }
        }
        .navigationBarHidden(true)
        .task { await load() }
    }

    private func load() async {
        // Best-effort: fetch the authoritative SKILL.md from GitHub raw.
        // Falls back to a baked pointer if network is unavailable.
        let url = URL(string: "https://raw.githubusercontent.com/Account-Link/feedling-mcp/main/skill/SKILL.md")!
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let s = String(data: data, encoding: .utf8) {
                runbookText = s
                return
            }
        } catch {}
        runbookText = """
Couldn't fetch the latest runbook from GitHub.

Point your agent at:
  https://github.com/Account-Link/feedling-mcp/blob/main/skill/SKILL.md

The runbook walks through: clone, deps, env, systemd units,
Caddy + Let's Encrypt, DNS, iOS → your URL + key.

Your data stays on your VPS. We stop being in the loop.
"""
    }
}

// MARK: - Compose-hash-changed consent (full-screen)

struct ComposeHashChangeConsentView: View {
    @ObservedObject private var api = FeedlingAPI.shared

    var body: some View {
        ZStack {
            Color.feedlingPaper.ignoresSafeArea()
            VStack(spacing: Spacing.lg) {
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.feedlingSage)
                    .accessibilityHidden(true)
                Text("Feedling has a new version.")
                    .multilineTextAlignment(.center)
                    .feedlingDisplay(.medium)
                Text("The app on your phone just saw a newer version of the Feedling server.")
                    .multilineTextAlignment(.center)
                    .feedlingBody()
                    .frame(maxWidth: 320)
                if let change = api.pendingComposeHashChange {
                    VStack(spacing: Spacing.sm) {
                        Text(change.oldHash.prefix(16) + "…")
                            .font(.feedlingMono())
                            .foregroundStyle(Color.feedlingInkMuted)
                        Image(systemName: "arrow.down")
                            .foregroundStyle(Color.feedlingSage)
                            .accessibilityLabel("changed to")
                        Text(change.newHash.prefix(16) + "…")
                            .font(.feedlingMono())
                            .foregroundStyle(Color.feedlingInk)
                    }
                    .padding(.top, Spacing.sm)
                }
                Text("Your existing encrypted memories and chat are still readable — they were encrypted to a key that's bound to your account, not to any specific server version.")
                    .multilineTextAlignment(.center)
                    .feedlingCaption()
                    .frame(maxWidth: 340)
                    .padding(.top, Spacing.sm)
                Spacer()
                VStack(spacing: Spacing.md) {
                    Button {
                        api.acceptComposeHashChange()
                    } label: { Text("Got it, continue") }
                        .buttonStyle(FeedlingPrimaryButtonStyle())
                    Button {
                        api.signOutForComposeChange()
                    } label: { Text("Sign out for now") }
                        .buttonStyle(FeedlingSecondaryButtonStyle())
                }
                .padding(.bottom, Spacing.xl2)
            }
            .padding(.horizontal, Spacing.xl)
        }
    }
}


// MARK: - Live dot (pulsing white indicator for active Live Activity)

private struct LiveDot: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.cinAccent1.opacity(0.3))
                .frame(width: 14, height: 14)
                .scaleEffect(pulse ? 1.7 : 1.0)
                .opacity(pulse ? 0 : 1)
            Circle()
                .fill(Color.cinAccent1)
                .frame(width: 7, height: 7)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

// MARK: - Phase B wave-2: memory visibility context menu

/// Adds a long-press context menu to a memory card so the user can
/// flip it between "Shared with agent" and "Hidden from agent" in
/// one action. Lives here instead of in MemoryGardenView.swift so the
/// Phase B wave-2 work stays consolidated in ContentView.swift alongside
/// the rest of the Privacy surface (MemoryGardenView.swift is iOS
/// MVP-era code and I don't want to bloat it).
extension View {
    func feedlingMemoryVisibilityMenu(
        moment: MemoryMoment,
        onFlip: @escaping (Bool) -> Void   // toLocalOnly
    ) -> some View {
        self.contextMenu {
            let currentlyLocal = moment.visibility == "local_only"
            if currentlyLocal {
                Button {
                    onFlip(false)   // flip to shared
                } label: {
                    Label("Share with agent", systemImage: "eye")
                }
            } else {
                Button {
                    onFlip(true)    // flip to local_only
                } label: {
                    Label("Hide from agent", systemImage: "eye.slash")
                }
            }
        }
    }
}
