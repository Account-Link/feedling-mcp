import SwiftUI
import UIKit

/// Settings → Health Check.
///
/// One screen that answers "is everything that should be working, working?"
/// Three sections, all read-only except the diagnostics buttons:
///   · CONNECTION         — agent activity + bootstrap milestones
///   · DEVICE FEATURES    — Live Activity, screen broadcast, APNs token
///   · DIAGNOSTICS        — fire test prompts at the agent + push test
///
/// Distinct from the empty-state ChatView in two ways:
///   1. This page is for *post-bootstrap* verification ("is X still alive?")
///   2. It exposes capability tests the empty state can't: vision, push.
struct HealthCheckView: View {

    @StateObject private var bootstrap = BootstrapStatusViewModel()
    @ObservedObject private var api = FeedlingAPI.shared
    @EnvironmentObject var lam: LiveActivityManager
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var chatVM: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isBroadcasting: Bool = false
    @State private var now: Date = Date()
    @State private var toastMsg: String? = nil

    private let broadcastPollTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let secondTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .top) {
            Color.cinBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    header
                    Rectangle().fill(Color.cinFg).frame(height: 1)
                    section("CONNECTION") {
                        connectionRows
                    }
                    section("DEVICE FEATURES") {
                        featureRows
                    }
                    section("DIAGNOSTICS") {
                        diagnosticRows
                    }
                    footer
                    Color.clear.frame(height: 40)
                }
            }

            if let toastMsg {
                Text(toastMsg)
                    .font(.dmMono(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.cinBg)
                    .kerning(2)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.cinFg)
                    .padding(.top, 22)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            router.enterDetail()
            bootstrap.startPolling(interval: 4)
            isBroadcasting = UserDefaults(suiteName: "group.com.feedling.mcp")?.bool(forKey: "isBroadcasting") ?? false
        }
        .onDisappear {
            router.exitDetail()
            bootstrap.stopPolling()
        }
        .onReceive(broadcastPollTimer) { _ in
            isBroadcasting = UserDefaults(suiteName: "group.com.feedling.mcp")?.bool(forKey: "isBroadcasting") ?? false
        }
        .onReceive(secondTicker) { now = $0 }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            Button {
                dismiss()
            } label: {
                Text("← settings")
                    .font(.dmMono(size: 9.5))
                    .foregroundStyle(Color.cinFg)
                    .kerning(2)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Health Check")
                .font(.newsreader(size: 13, italic: true))
                .foregroundStyle(Color.cinFg)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - CONNECTION

    private var connectionRows: some View {
        VStack(spacing: 0) {
            statusRow(
                label: "Agent",
                state: bootstrap.status.agentConnected ? .ok : .pending,
                detail: bootstrap.status.lastActivityRelative(now: now) ?? "never seen"
            )
            statusRow(
                label: "Identity card",
                state: bootstrap.status.identityWritten ? .ok : .pending,
                detail: bootstrap.status.identityWritten ? "written" : "not yet"
            )
            statusRow(
                label: "Memories",
                state: bootstrap.status.memoriesCount >= 3 ? .ok :
                       bootstrap.status.memoriesCount > 0 ? .partial : .pending,
                detail: "\(bootstrap.status.memoriesCount) cards"
            )
            statusRow(
                label: "Chat round-trip",
                state: bootstrap.status.agentMessagesCount >= 1 ? .ok : .pending,
                detail: bootstrap.status.agentMessagesCount >= 1
                    ? "\(bootstrap.status.agentMessagesCount) replies"
                    : "no agent reply yet"
            )
        }
    }

    // MARK: - DEVICE FEATURES

    private var featureRows: some View {
        VStack(spacing: 0) {
            statusRow(
                label: "Live Activity",
                state: lam.isActive ? .ok : .pending,
                detail: lam.isActive ? "active" : "not started"
            )
            // Broadcast row — read-only status. The "start broadcast" picker
            // already lives in Settings → Recording (existing big card).
            // Surfacing a second picker here would visually overlap the
            // status text and split the user-facing entry-points.
            statusRow(
                label: "Screen broadcast",
                state: isBroadcasting ? .ok : .warn,
                detail: isBroadcasting ? "running" : "not running · start in Settings"
            )
            statusRow(
                label: "APNs token",
                state: (lam.deviceToken?.isEmpty == false) ? .ok : .pending,
                detail: lam.deviceToken == nil ? "pending" : "registered"
            )
        }
    }

    // MARK: - DIAGNOSTICS

    private var diagnosticRows: some View {
        VStack(spacing: 0) {
            diagnosticRow(
                title: "Verify reply pipeline",
                description: "服务端发个 synthetic ping 等 30s 看 agent 真的回。抓 stopgap / 假 bridge。",
                action: { runVerifyLoop() }
            )
            diagnosticRow(
                title: "Test chat round-trip",
                description: "发一条 ping 给 agent，去 Chat 看回复。",
                action: { runChatPing() }
            )
            diagnosticRow(
                title: "Test vision",
                description: "让 agent 描述当前屏幕。需要 broadcast 在跑。",
                action: { runVisionTest() }
            )
            diagnosticRow(
                title: "Test live activity push",
                description: "刷新一条本地预览到锁屏 / 灵动岛。",
                action: { runLiveActivityTest() }
            )
        }
    }

    /// Server-side synthetic ping. Server posts a marker user message,
    /// waits 30 s for an agent reply, returns result. Distinct from
    /// "test chat round-trip" because (a) the ping is invisible to the
    /// user's chat history (synthetic message is GC'd), (b) the server
    /// directly observes whether a real reply landed, (c) catches the
    /// stopgap-bridge failure mode where the chat *appears* responsive
    /// but is actually a template echo bot.
    private func runVerifyLoop() {
        showToast("Pinging agent — wait up to 30s")
        Task {
            do {
                let result = try await api.verifyChatLoop()
                await MainActor.run {
                    if result.passing {
                        let t = String(format: "%.1f", result.responseTimeSec ?? 0)
                        showToast("Loop alive · agent replied in \(t)s")
                    } else {
                        showToast("Loop DEAD — agent didn't reply. Check daemon.")
                    }
                }
            } catch {
                await MainActor.run {
                    showToast("Verify failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func diagnosticRow(
        title: String,
        description: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.notoSerifSC(size: 13.5))
                        .foregroundStyle(Color.cinFg)
                    Spacer()
                    Text("RUN ↗")
                        .font(.dmMono(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.cinAccent1)
                        .kerning(2)
                }
                Text(description)
                    .font(.notoSerifSC(size: 11.5))
                    .foregroundStyle(Color.cinSub)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.horizontal, 24)
        }
    }

    // MARK: - Diagnostic actions

    private func runChatPing() {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        sendDiagnostic(
            text: "[health check · \(ts)] ping — please reply with anything.",
            toast: "Sent — switching to chat"
        )
    }

    private func runVisionTest() {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        sendDiagnostic(
            text: "[health check · \(ts)] 用 feedling_screen_decrypt_frame 看一下我现在屏幕，告诉我你看到的关键文字或界面，至少一句话。",
            toast: "Sent — switching to chat"
        )
    }

    /// Switch tab + show toast IMMEDIATELY so the user sees response within
    /// one frame, then fire the encrypted POST in the background.
    /// (sendMessage takes ~1 s for the network round-trip; we don't want the
    /// user staring at the Settings page during that.)
    private func sendDiagnostic(text: String, toast: String) {
        chatVM.inputText = text
        router.selectedTab = .chat
        showToast(toast)
        Task { await chatVM.sendMessage() }
    }

    private func runLiveActivityTest() {
        guard lam.isActive else {
            showToast("Live Activity 未启用")
            return
        }
        Task {
            let testState = ScreenActivityAttributes.ContentState(
                title: "Health Check",
                subtitle: "TEST · \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))",
                body: "如果你在锁屏 / 灵动岛看到这条，推送通路是通的。",
                data: [:],
                updatedAt: Date()
            )
            await lam.updateActivity(state: testState)
            await MainActor.run {
                showToast("Pushed — check your lock screen")
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This page polls every 4s.")
                .font(.dmMono(size: 8.5))
                .foregroundStyle(Color.cinSub)
                .kerning(1.2)
            if let last = bootstrap.lastFetchAt {
                Text("Last refresh: \(relative(last))")
                    .font(.dmMono(size: 8.5))
                    .foregroundStyle(Color.cinSub)
                    .kerning(1.2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 22)
    }

    private func relative(_ date: Date) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 5     { return "just now" }
        if interval < 60    { return "\(Int(interval))s ago" }
        if interval < 3600  { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }

    // MARK: - Section + status row primitives

    private func section<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.dmMono(size: 9.5, weight: .medium))
                .foregroundStyle(Color.cinAccent1)
                .kerning(3)
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 10)
            content()
        }
    }

    private enum RowState {
        case ok      // green-ish (we use cinAccent1 for warmth)
        case partial // amber-ish (use cinSub)
        case warn    // attention (use cinAccent2)
        case pending // grey/empty
    }

    private func statusRow(label: String, state: RowState, detail: String) -> some View {
        HStack(spacing: 12) {
            statusGlyph(state)
            Text(label)
                .font(.notoSerifSC(size: 13.5))
                .foregroundStyle(Color.cinFg)
            Spacer()
            Text(detail)
                .font(.dmMono(size: 9))
                .foregroundStyle(Color.cinSub)
                .kerning(1.5)
                .lineLimit(1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private func statusGlyph(_ state: RowState) -> some View {
        switch state {
        case .ok:
            ZStack {
                Circle()
                    .stroke(Color.cinAccent1, lineWidth: 1)
                    .frame(width: 14, height: 14)
                Image(systemName: "checkmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.cinAccent1)
            }
        case .partial:
            Circle()
                .fill(Color.cinSub)
                .frame(width: 6, height: 6)
                .padding(4)
        case .warn:
            ZStack {
                Circle()
                    .stroke(Color.cinAccent2, lineWidth: 1)
                    .frame(width: 14, height: 14)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.cinAccent2)
            }
        case .pending:
            Circle()
                .stroke(Color.cinLine, lineWidth: 1)
                .frame(width: 14, height: 14)
        }
    }

    // MARK: - Toast

    private func showToast(_ msg: String) {
        withAnimation(.easeInOut(duration: 0.2)) { toastMsg = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeInOut(duration: 0.25)) { toastMsg = nil }
        }
    }
}
