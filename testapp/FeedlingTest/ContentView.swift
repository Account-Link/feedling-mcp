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
                    withAnimation(FeedlingMotion.enter) { onboardingShown = true }
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
        .tint(Color.feedlingSage)
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
                    // Phase B: Privacy is its own top-level destination.
                    // The Settings → Privacy page contains the hero row,
                    // audit card, export / delete / reset, visibility,
                    // and the "run your own" branch.
                    Section {
                        NavigationLink {
                            PrivacyPageView()
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Privacy")
                                        .font(.headline)
                                        .foregroundStyle(Color.feedlingInk)
                                    Text("Encrypted data, export, delete, audit")
                                        .font(.footnote)
                                        .foregroundStyle(Color.feedlingInkMuted)
                                }
                            } icon: {
                                Image(systemName: "lock.shield")
                                    .foregroundStyle(Color.feedlingSage)
                            }
                        }
                    }

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
    @State private var showExportSheet = false
    @State private var showDeleteSheet = false
    @State private var showResetSheet = false
    @State private var toast: String? = nil

    var body: some View {
        List {
            Section {
                NavigationLink {
                    AuditCardPage()
                } label: {
                    PrivacyHeroRow()
                }
                .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.md,
                                          bottom: Spacing.sm, trailing: Spacing.md))
                // Phase B wave-2: inline migration progress when the
                // silent v0→v1 rewrap is in flight. Hidden otherwise.
                if let prog = api.migrationProgress {
                    MigrationProgressRow(done: prog.done, total: prog.total)
                        .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.md,
                                                  bottom: Spacing.sm, trailing: Spacing.md))
                }
            }
            Section("Your data") {
                Button {
                    showExportSheet = true
                } label: {
                    Label("Export my data", systemImage: "square.and.arrow.up")
                        .foregroundStyle(Color.feedlingInk)
                }
                Button {
                    showDeleteSheet = true
                } label: {
                    Label("Delete my data", systemImage: "trash")
                        .foregroundStyle(.red)
                }
                Button {
                    showResetSheet = true
                } label: {
                    Label("Reset & re-import (advanced)",
                          systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Color.feedlingInk)
                }
            }
            Section("Where your data lives") {
                NavigationLink {
                    StorageBackendView()
                } label: {
                    Label("Backend: \(api.storageMode == .cloud ? "Feedling Cloud" : "Self-hosted")",
                          systemImage: "server.rack")
                }
                NavigationLink {
                    RunbookView()
                } label: {
                    Label("Help me run my own server", systemImage: "doc.text.magnifyingglass")
                }
            }
            Section("Advanced") {
                NavigationLink {
                    AuditCardPage()
                } label: {
                    Label("Re-run privacy audit", systemImage: "checkmark.shield")
                }
                Button {
                    FeedlingAPI.shared.hasCompletedOnboardingV1 = false
                    toast = "Intro will show on next launch"
                } label: {
                    Label("Show the intro again", systemImage: "sparkles")
                        .foregroundStyle(Color.feedlingInk)
                }
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showExportSheet) { ExportSheet() }
        .sheet(isPresented: $showDeleteSheet) { DeleteSheet() }
        .sheet(isPresented: $showResetSheet) { ResetAndReimportSheet() }
        .overlay(alignment: .bottom) {
            if let msg = toast {
                Text(msg).feedlingCaption()
                    .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, Spacing.xl)
                    .transition(.opacity)
            }
        }
        .onChange(of: toast) { newValue in
            if newValue != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { toast = nil }
                }
            }
        }
    }
}

private struct PrivacyHeroRow: View {
    @ObservedObject private var api = FeedlingAPI.shared
    @State private var lastVerifiedAt: Date? = nil

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: heroIcon)
                .font(.system(size: 28))
                .foregroundStyle(heroColor)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(heroTitle)
                    .font(.headline)
                    .foregroundStyle(Color.feedlingInk)
                Text(heroSubtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.feedlingInkMuted)
            }
            Spacer()
        }
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
    }

    private var heroIcon: String {
        api.enclaveComposeHash != nil ? "checkmark.shield.fill" : "shield"
    }
    private var heroColor: Color {
        api.enclaveComposeHash != nil ? Color.feedlingSage : Color.feedlingInkMuted
    }
    private var heroTitle: String {
        if api.enclaveComposeHash == nil { return "Privacy audit not yet run" }
        return "Everything you've written is encrypted"
    }
    private var heroSubtitle: String {
        if let h = api.enclaveComposeHash {
            return "Compose \(h.prefix(8))… · tap for full audit"
        }
        return "Tap to run the audit"
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


// MARK: - Phase B wave-2: inline migration progress row

struct MigrationProgressRow: View {
    let done: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Upgrading your old data — \(done) of \(total)")
                    .feedlingCaption()
            }
            ProgressView(value: Double(done), total: Double(total))
                .progressViewStyle(.linear)
                .tint(Color.feedlingSage)
        }
        .padding(.vertical, 2)
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
