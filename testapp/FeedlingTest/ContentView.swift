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
                .padding(.bottom, 52 + geo.safeAreaInsets.bottom)

                CinnabarTabBar(selectedTab: $router.selectedTab,
                               bottomInset: geo.safeAreaInsets.bottom)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .preferredColorScheme(.light)
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
            ZStack {
                Color.cinBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        settingsHeader
                        Rectangle().fill(Color.cinFg).frame(height: 1)
                        screenRecordingCard
                        settingsSection("STORAGE") {
                            cinRow("Backend") {
                                Picker("", selection: $api.storageMode) {
                                    Text("Cloud").tag(FeedlingAPI.StorageMode.cloud)
                                    Text("Self-hosted").tag(FeedlingAPI.StorageMode.selfHosted)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 160)
                                .onChange(of: api.storageMode) { newMode in
                                    if newMode == .cloud {
                                        api.configureCloud()
                                        Task { await api.ensureRegisteredIfCloud() }
                                    }
                                }
                            }
                            if api.storageMode == .selfHosted {
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
                        settingsSection("AGENT") {
                            cinCopyRow("MCP String", value: api.mcpConnectionString, label: "COPY ↗") {
                                UIPasteboard.general.string = api.mcpConnectionString
                                showToast("Copied MCP string")
                            }
                            cinCopyRow("Env Vars", value: api.envExportBlock, label: "COPY ↗") {
                                UIPasteboard.general.string = api.envExportBlock
                                showToast("Copied env vars")
                            }
                            if api.storageMode == .cloud {
                                cinActionRow("REGENERATE API KEY ↗", color: .cinAccent2) {
                                    Task {
                                        await api.regenerateCredentials()
                                        showToast("Key regenerated")
                                    }
                                }
                            }
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
                        settingsSection("LIVE ACTIVITY") {
                            cinRow("Status") {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(lam.isActive ? Color.cinAccent1 : Color.cinLine)
                                        .frame(width: 7, height: 7)
                                    Text(lam.isActive ? "Active" : "Inactive")
                                        .font(.dmMono(size: 10))
                                        .foregroundStyle(lam.isActive ? Color.cinAccent1 : Color.cinSub)
                                }
                            }
                            if let state = lam.lastState {
                                cinRow("Last Title") {
                                    Text(state.title).font(.dmMono(size: 9)).foregroundStyle(Color.cinSub)
                                }
                            }
                            if !lam.isActive {
                                cinActionRow("START LIVE ACTIVITY ↗", color: .cinFg) {
                                    Task { await lam.startActivity() }
                                }
                            } else {
                                cinActionRow("SIMULATE UPDATE ↗", color: .cinFg) {
                                    let s = mockStates[mockIndex % mockStates.count]; mockIndex += 1
                                    Task { await lam.updateActivity(state: s) }
                                }
                                cinActionRow("STOP LIVE ACTIVITY ↗", color: .cinAccent2) {
                                    Task { await lam.stopActivity() }
                                }
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
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                        }
                        settingsFooter
                    }
                }
            }
            .navigationBarHidden(true)
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
            // Section label (matches other settingsSection headers)
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text("SCREEN RECORDING")
                    .font(.dmMono(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.cinAccent1)
                    .kerning(3)
                Rectangle().fill(Color.cinFg.opacity(0.18)).frame(height: 0.5)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 12)

            // Card
            VStack(alignment: .leading, spacing: 0) {
                // Description
                VStack(alignment: .leading, spacing: 5) {
                    Text("开启后 Agent 可以实时看到屏幕内容")
                        .font(.notoSerifSC(size: 13.5))
                        .foregroundStyle(Color.cinFg)
                    Text("用于持续了解你正在做什么，让 Agent 的建议更贴近当下")
                        .font(.interTight(size: 11.5))
                        .foregroundStyle(Color.cinSub)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 14)

                Rectangle().fill(Color.cinAccent1.opacity(0.2)).frame(height: 1)

                // Tap-to-record row — BroadcastPickerView is the actual tap target;
                // the SwiftUI label floats on top with hit-testing disabled.
                ZStack {
                    HStack(spacing: 8) {
                        Circle().fill(Color.cinAccent1).frame(width: 7, height: 7)
                        Text("TAP TO START RECORDING ↗")
                            .font(.dmMono(size: 9, weight: .medium))
                            .foregroundStyle(Color.cinAccent1)
                            .kerning(2.5)
                    }
                    .allowsHitTesting(false)

                    BroadcastPickerView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(0.011)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
            }
            .background(Color.cinAccent1Soft)
            .overlay { Rectangle().stroke(Color.cinAccent1.opacity(0.3), lineWidth: 1) }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }

    private var settingsFooter: some View {
        HStack {
            Text("她记得的，比她说的多。")
                .font(.newsreader(size: 11, italic: true))
                .foregroundStyle(Color.cinSub)
            Spacer()
            Text("FEEDLING")
                .font(.dmMono(size: 8.5))
                .foregroundStyle(Color.cinSub)
                .kerning(2)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 32)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.cinFg).frame(height: 1)
        }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(label)
                    .font(.dmMono(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.cinAccent1)
                    .kerning(3)
                Rectangle().fill(Color.cinFg.opacity(0.18)).frame(height: 0.5)
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
            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.leading, 24)
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
        .overlay(alignment: .top) {
            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.leading, 24)
        }
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
            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.leading, 24)
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
            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.leading, 24)
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
                Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.leading, 24)
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
        for subview in picker.subviews {
            if let button = subview as? UIButton {
                button.imageView?.tintColor = .clear
                button.backgroundColor = .clear
            }
        }
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) { }
}


// ============================================================================
// Phase B — Onboarding, Privacy page, Export / Delete / Reset, Runbook viewer.
//
// All these views live here because the Xcode project references source files
// explicitly; adding new .swift files requires project.pbxproj edits that
// aren't safe from the filesystem. Keeping them consolidated in one compiled
// file is the pragmatic tradeoff. DESIGN.md tokens apply throughout.
// ============================================================================

// MARK: - Onboarding (three slides, first-run only, dismissable via Settings)

struct OnboardingView: View {
    let onDone: () -> Void
    @State private var page: Int = 0

    var body: some View {
        ZStack {
            Color.feedlingPaper.ignoresSafeArea()
            TabView(selection: $page) {
                OnboardingSlide(
                    glyph: "lock.shield",
                    headline: "Your conversations live here,\nnot with us.",
                    bodyText: "Every message, memory, and note about your agent is encrypted with a key that only your iPhone holds. Feedling's servers store the ciphertext — we literally don't have the secret that unlocks it.",
                    primaryLabel: "Next",
                    primaryAction: { withAnimation(FeedlingMotion.enter) { page = 1 } }
                ).tag(0)

                OnboardingSlide(
                    glyph: "arrow.triangle.branch",
                    headline: "We host the vault,\nyou hold the key.",
                    bodyText: "You don't have to trust us — you can audit the proof from Settings any time.",
                    secondaryContent: AnyView(OnboardingTwoColumn()),
                    primaryLabel: "Next",
                    primaryAction: { withAnimation(FeedlingMotion.enter) { page = 2 } }
                ).tag(1)

                OnboardingSlide(
                    glyph: "hand.raised.square.on.square",
                    headline: "Walk away\nwhenever you want.",
                    bodyText: "Nothing is irreversible.",
                    secondaryContent: AnyView(OnboardingControlRows()),
                    primaryLabel: "Get started",
                    primaryAction: onDone
                ).tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
        }
    }
}

private struct OnboardingSlide: View {
    let glyph: String
    let headline: String
    let bodyText: String
    var secondaryContent: AnyView? = nil
    let primaryLabel: String
    let primaryAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Spacing.xl)

            Image(systemName: glyph)
                .font(.system(size: 96, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.feedlingSage)
                .accessibilityHidden(true)
                .padding(.top, Spacing.xl)

            Spacer(minLength: Spacing.xl2)

            VStack(spacing: Spacing.lg) {
                Text(headline)
                    .multilineTextAlignment(.center)
                    .feedlingDisplay(.medium)
                    .fixedSize(horizontal: false, vertical: true)

                Text(bodyText)
                    .multilineTextAlignment(.center)
                    .feedlingBody()
                    .frame(maxWidth: 320)
                    .fixedSize(horizontal: false, vertical: true)

                if let sc = secondaryContent {
                    sc.padding(.top, Spacing.md)
                }
            }
            .padding(.horizontal, Spacing.xl)

            Spacer()

            Button(action: primaryAction) {
                Text(primaryLabel)
            }
            .buttonStyle(FeedlingPrimaryButtonStyle())
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xl3)
        }
    }
}

private struct OnboardingTwoColumn: View {
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("We handle:")
                    .feedlingCaption()
                OBRow("lock.doc", "Ciphertext of your chat, memory, identity")
                OBRow("clock", "Timestamps so things sort")
                OBRow("bell.badge", "Push tokens for the Dynamic Island")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Only your phone can read:")
                    .feedlingCaption()
                OBRow("bubble.left.and.bubble.right", "The message text itself")
                OBRow("leaf", "Every memory in your garden")
                OBRow("person.text.rectangle", "Your agent's identity card")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, Spacing.sm)
    }
}

private struct OBRow: View {
    let symbol: String
    let text: String
    init(_ symbol: String, _ text: String) { self.symbol = symbol; self.text = text }
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: symbol)
                .foregroundStyle(Color.feedlingSage)
                .font(.footnote)
                .frame(width: 16, alignment: .center)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.feedlingInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardingControlRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            OBRow("square.and.arrow.up", "Take your data out — a decrypted archive, yours to keep.")
            OBRow("trash", "Delete everything — no trace on any of our servers.")
            OBRow("server.rack", "Host it yourself — the runbook walks your agent through it.")
        }
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
                            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.leading, 24)
                        }
                    }
                    privacySection("YOUR DATA") {
                        privacyActionRow("EXPORT MY DATA ↗", color: .cinFg) { showExportSheet = true }
                        privacyActionRow("DELETE MY DATA ↗", color: .cinAccent2) { showDeleteSheet = true }
                        privacyActionRow("RESET & RE-IMPORT ↗", color: .cinSub) { showResetSheet = true }
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
                            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.leading, 24)
                        }

                        NavigationLink {
                            RunbookView()
                        } label: {
                            privacyLinkRow("Self-hosting runbook")
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.leading, 24)
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
                            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.leading, 24)
                        }

                        privacyActionRow("SHOW INTRO AGAIN ↗", color: .cinSub) {
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
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(label)
                    .font(.dmMono(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.cinAccent1)
                    .kerning(3)
                Rectangle().fill(Color.cinFg.opacity(0.18)).frame(height: 0.5)
            }
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
    private func privacyActionRow(_ label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.dmMono(size: 9.5, weight: .medium))
                .foregroundStyle(color)
                .kerning(2)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.leading, 24)
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
    var body: some View {
        ScrollView {
            AuditCardView()
                .padding(Spacing.md)
        }
        .background(Color.feedlingPaper.ignoresSafeArea())
        .navigationTitle("Privacy audit")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// Thin wrapper around the existing Storage configuration rows so
// Privacy's "Where your data lives" can dive into them directly.
struct StorageBackendView: View {
    @ObservedObject private var api = FeedlingAPI.shared
    @State private var url: String = ""
    @State private var key: String = ""

    var body: some View {
        List {
            Section("Backend") {
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
                    TextField("https://my-vps.example:5001", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                        .onAppear { url = api.baseURL }
                    TextField("API key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                        .onAppear { key = api.apiKey }
                    Button("Save self-hosted config") {
                        api.configureSelfHosted(url: url, apiKey: key)
                    }
                    .disabled(url.isEmpty)
                }
            }
            Section("Reference") {
                LabeledContent("API URL", value: api.baseURL)
                    .font(.caption)
                LabeledContent("User ID", value: api.userId.isEmpty ? "—" : api.userId)
                    .font(.caption)
            }
        }
        .navigationTitle("Backend")
        .navigationBarTitleDisplayMode(.inline)
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
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Label("Export my data", systemImage: "square.and.arrow.up")
                .font(.headline)
            Text("This assembles every item on your account into a single JSON file and hands it to the iOS share sheet.")
                .font(.callout)
                .foregroundStyle(Color.feedlingInk)
            Text("Note: if you save the file to iCloud Drive, the unencrypted copy leaves your phone. Save to Files (On My iPhone) to keep it local.")
                .font(.footnote)
                .foregroundStyle(Color.feedlingInkMuted)
            if let err = error {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
            Spacer()
            if running {
                ProgressView("Packaging…")
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    Task { await runExport() }
                } label: {
                    Text("Export")
                }
                .buttonStyle(FeedlingPrimaryButtonStyle())
            }
            Button("Cancel", action: { dismiss() })
                .buttonStyle(FeedlingSecondaryButtonStyle())
        }
        .padding(Spacing.xl)
        .sheet(isPresented: $showShareSheet) {
            if let result = exportData,
               let tmp = writeTempFile(result) {
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
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Label("Delete everything?", systemImage: "trash")
                .font(.headline)
                .foregroundStyle(.red)
            Text("This revokes your account, deletes every ciphertext blob on our servers, and wipes the keys on this device. It cannot be undone.")
                .font(.callout)
                .foregroundStyle(Color.feedlingInk)

            Toggle(isOn: $downloadFirst) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download my data first")
                        .font(.callout.weight(.semibold))
                    Text("Keeps a decrypted archive via the iOS share sheet before your account is deleted.")
                        .font(.footnote)
                        .foregroundStyle(Color.feedlingInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Color.feedlingSage)

            if let err = error {
                Text(err).font(.footnote).foregroundStyle(.red)
            }

            Spacer()

            if running {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    Task { await runDelete() }
                } label: {
                    Text("Delete")
                }
                .buttonStyle(FeedlingPrimaryButtonStyle(destructive: true))
            }
            Button("Cancel", action: { dismiss() })
                .buttonStyle(FeedlingSecondaryButtonStyle())
        }
        .padding(Spacing.xl)
        .sheet(isPresented: $showShareSheet, onDismiss: {
            // After the user finishes the share sheet (or cancels),
            // proceed with the actual delete.
            if pendingDelete {
                Task { await performFinalDelete() }
            }
        }) {
            if let r = exportedToShare,
               let tmp = writeTempFile(r) {
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
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Label("Reset & re-import", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
            Text("Three steps: download your data, delete your old account, register a new one. The new account gets fresh keys — use the MCP connection string to walk your agent through importing everything back.")
                .font(.callout)
                .foregroundStyle(Color.feedlingInk)
            if let err = error {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
            HStack(spacing: Spacing.md) {
                stepDot(1, active: step >= 1)
                Text("Export")
                    .feedlingCaption()
                Spacer(minLength: 0)
                stepDot(2, active: step >= 2)
                Text("Delete")
                    .feedlingCaption()
                Spacer(minLength: 0)
                stepDot(3, active: step >= 3)
                Text("Re-register")
                    .feedlingCaption()
            }
            Spacer()
            Button {
                Task { await runPipeline() }
            } label: {
                Text(step >= 3 ? "Done" : "Start")
            }
            .buttonStyle(FeedlingPrimaryButtonStyle())
            Button("Cancel", action: { dismiss() })
                .buttonStyle(FeedlingSecondaryButtonStyle())
        }
        .padding(Spacing.xl)
    }

    private func stepDot(_ n: Int, active: Bool) -> some View {
        ZStack {
            Circle()
                .fill(active ? Color.feedlingSage : Color.feedlingDivider)
                .frame(width: 22, height: 22)
            Text("\(n)").font(.caption2.bold()).foregroundStyle(.white)
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
    @State private var runbookText: String = "Loading…"

    var body: some View {
        ScrollView {
            Text(runbookText)
                .font(.footnote.monospaced())
                .foregroundStyle(Color.feedlingInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.md)
        }
        .background(Color.feedlingPaper.ignoresSafeArea())
        .navigationTitle("Self-hosted runbook")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = runbookText
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
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
