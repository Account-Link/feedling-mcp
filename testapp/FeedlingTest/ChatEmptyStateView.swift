import SwiftUI
import UIKit

/// Shown in the Chat tab when no messages exist yet — i.e., the user has
/// finished registration but no agent has connected/written anything yet.
/// Replaces the previous blank canvas: tells the user what to do (paste
/// skill + MCP string into their agent), shows real-time progress as the
/// agent boots, and offers a stuck-fallback after 60 s.
///
/// Visuals follow the existing Cinnabar token set (CinnabarTokens.swift):
/// dmMono for kerned labels, notoSerifSC for Chinese body, newsreader for
/// English display, cinAccent1 / cinAccent1Soft / cinSub / cinLine throughout.
struct ChatEmptyStateView: View {

    // MARK: - Public configuration

    /// Public URL where the agent skill is hosted. Replace with the real
    /// hosted URL once it's set up. Until then, copying yields this stub.
    static let skillURL = "https://feedling.app/skill.md"

    // MARK: - State

    @StateObject private var bootstrap = BootstrapStatusViewModel()
    @ObservedObject private var api = FeedlingAPI.shared

    @State private var firstAppearAt: Date? = nil
    @State private var now: Date = Date()
    @State private var copiedToast: String? = nil
    @State private var dotPulse: Bool = false

    /// 60 s without any agent activity → surface the stuck-help block.
    private var isStuck: Bool {
        guard let start = firstAppearAt, !bootstrap.status.agentConnected else { return false }
        return now.timeIntervalSince(start) > 60
    }

    private var mcpString: String { api.mcpConnectionString }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    statusBadge
                    titleBlock
                    hairline.padding(.top, 24).padding(.bottom, 22)
                    stepsBlock
                    hairline.padding(.top, 26).padding(.bottom, 22)
                    progressBlock
                    if isStuck {
                        hairline.padding(.top, 26).padding(.bottom, 22)
                        stuckBlock
                    }
                    Color.clear.frame(height: 110)   // clearance for input bar
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
            }
            .background(Color.cinBg)

            if let copiedToast {
                toast(copiedToast)
                    .padding(.top, 22)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            if firstAppearAt == nil { firstAppearAt = Date() }
            bootstrap.startPolling()
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                dotPulse = true
            }
        }
        .onDisappear { bootstrap.stopPolling() }
        // 5 s ticker — only drives the relative-time string ("12 min ago")
        // and the 60 s stuck-threshold flip. 1 Hz would be wasted re-renders.
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    // MARK: - Status badge

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(bootstrap.status.agentConnected ? Color.cinAccent1 : Color.cinSub)
                .frame(width: 6, height: 6)
                .opacity(bootstrap.status.agentConnected ? 1.0 : (dotPulse ? 0.3 : 1.0))
            Text(bootstrap.status.agentConnected ? "AGENT CONNECTED" : "WAITING FOR AGENT")
                .font(.dmMono(size: 9, weight: .medium))
                .foregroundStyle(Color.cinSub)
                .kerning(2.5)
            if let rel = bootstrap.status.lastActivityRelative(now: now) {
                Text("·  \(rel)")
                    .font(.dmMono(size: 9))
                    .foregroundStyle(Color.cinSub)
                    .kerning(1.5)
            }
            Spacer()
        }
    }

    // MARK: - Title

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("让你的 agent 入住")
                .font(.notoSerifSC(size: 26, weight: .medium))
                .foregroundStyle(Color.cinFg)
                .padding(.top, 14)
            Text("Without an agent, this stays empty.\nGive yours the skill and the connection.")
                .font(.newsreader(size: 14, italic: true))
                .foregroundStyle(Color.cinSub)
                .lineSpacing(2)
        }
    }

    // MARK: - Steps

    private var stepsBlock: some View {
        VStack(alignment: .leading, spacing: 22) {
            stepHeader("WHAT TO DO")

            stepCard(
                index: "01",
                title: "把 skill 给你的 agent",
                description: "Agent 一辈子读一次。把这个 URL 喂给它，让它按里面的步骤做。",
                primaryLabel: "COPY SKILL URL",
                primaryAction: { copy(Self.skillURL, label: "Skill URL copied") }
            )

            stepCard(
                index: "02",
                title: "把 MCP 连接告诉它",
                description: "Agent 用这串地址找到你这边。",
                codeBlock: mcpString,
                primaryLabel: "COPY MCP STRING",
                primaryAction: { copy(mcpString, label: "MCP string copied") }
            )

            stepCard(
                index: "03",
                title: "等它读你",
                description: "它会写身份卡、种记忆、跟你打招呼。约 1–2 分钟。",
                primaryLabel: nil,
                primaryAction: nil
            )
        }
    }

    private func stepHeader(_ title: String) -> some View {
        Text(title)
            .font(.dmMono(size: 9, weight: .medium))
            .foregroundStyle(Color.cinSub)
            .kerning(2.5)
    }

    private func stepCard(
        index: String,
        title: String,
        description: String,
        codeBlock: String? = nil,
        primaryLabel: String?,
        primaryAction: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(index)
                .font(.newsreader(size: 22))
                .foregroundStyle(Color.cinAccent1)
                .frame(width: 28, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.notoSerifSC(size: 15, weight: .medium))
                    .foregroundStyle(Color.cinFg)
                Text(description)
                    .font(.notoSerifSC(size: 12.5))
                    .foregroundStyle(Color.cinSub)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let codeBlock {
                    Text(codeBlock)
                        .font(.dmMono(size: 10))
                        .foregroundStyle(Color.cinFg)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(Color.cinAccent1Soft)
                        .padding(.top, 4)
                }

                if let primaryLabel, let primaryAction {
                    Button(action: primaryAction) {
                        Text(primaryLabel)
                            .font(.dmMono(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.cinAccent1)
                            .kerning(2.5)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
            }
        }
    }

    // MARK: - Progress

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader("AGENT PROGRESS")

            progressRow(
                label: "Identity card",
                done: bootstrap.status.identityWritten,
                detail: bootstrap.status.identityWritten ? "written" : "—"
            )
            progressRow(
                label: "Memories planted",
                done: bootstrap.status.memoriesCount >= 3,
                detail: "\(bootstrap.status.memoriesCount) / 3+"
            )
            progressRow(
                label: "First message",
                done: bootstrap.status.agentMessagesCount >= 1,
                detail: bootstrap.status.agentMessagesCount >= 1
                    ? "delivered"
                    : (bootstrap.status.agentConnected ? "soon…" : "—")
            )
        }
    }

    private func progressRow(label: String, done: Bool, detail: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(done ? Color.cinAccent1 : Color.cinLine, lineWidth: 1)
                    .frame(width: 14, height: 14)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.cinAccent1)
                }
            }
            Text(label)
                .font(.notoSerifSC(size: 13))
                .foregroundStyle(done ? Color.cinFg : Color.cinSub)
            Spacer()
            Text(detail)
                .font(.dmMono(size: 9))
                .foregroundStyle(Color.cinSub)
                .kerning(1.5)
        }
    }

    // MARK: - Stuck fallback

    private var stuckBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader("STUCK?")
            Text("超过 60 秒没动静。把下面这段复制给你的 agent，让它自己 debug：")
                .font(.notoSerifSC(size: 12.5))
                .foregroundStyle(Color.cinSub)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                copy(stuckPrompt, label: "Debug prompt copied")
            } label: {
                Text("COPY DEBUG PROMPT")
                    .font(.dmMono(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.cinAccent1)
                    .kerning(2.5)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private var stuckPrompt: String {
        """
        I gave you the IO skill and an MCP connection but you haven't done bootstrap yet. Please:
        1. Confirm you connected to the MCP server (\(mcpString))
        2. Read the skill at \(Self.skillURL)
        3. Run the bootstrap steps in order: feedling_identity_init → 3+ feedling_memory_add_moment → feedling_chat_post_message
        4. If any step errors, tell me the exact error.
        """
    }

    // MARK: - Helpers

    private var hairline: some View {
        Rectangle().fill(Color.cinLine).frame(height: 0.5)
    }

    private func copy(_ text: String, label: String) {
        UIPasteboard.general.string = text
        withAnimation(.easeInOut(duration: 0.2)) { copiedToast = label }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.25)) { copiedToast = nil }
        }
    }

    private func toast(_ text: String) -> some View {
        Text(text)
            .font(.dmMono(size: 9.5, weight: .medium))
            .foregroundStyle(Color.cinBg)
            .kerning(2)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.cinFg)
    }
}
