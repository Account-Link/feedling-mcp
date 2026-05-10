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

    /// Public URL where the agent skill is hosted. Mirror lives at
    /// github.com/teleport-computer/io-onboarding — update there + reflect
    /// here if the hosting moves.
    static let skillURL = "https://raw.githubusercontent.com/teleport-computer/io-onboarding/main/skill.md"

    // MARK: - State

    @StateObject private var bootstrap = BootstrapStatusViewModel()
    @ObservedObject private var api = FeedlingAPI.shared

    @State private var firstAppearAt: Date? = nil
    @State private var now: Date = Date()
    @State private var copiedToast: String? = nil
    @State private var dotPulse: Bool = false

    /// Bootstrap is now expected to take 10–60 minutes (memories-first flow).
    /// "Stuck" means meaningfully longer than that with no progress; we surface
    /// the help block at 5 minutes of zero agent activity (no identity, no
    /// memories, no messages) — earlier and the user gets nudged for what is
    /// actually normal long-bootstrap behavior.
    private var isStuck: Bool {
        guard let start = firstAppearAt, !bootstrap.status.agentConnected else { return false }
        return now.timeIntervalSince(start) > 5 * 60
    }

    private var mcpString: String { api.mcpConnectionString }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    statusBadge
                    titleBlock
                    hairline.padding(.vertical, 16)
                    stepsBlock
                    hairline.padding(.vertical, 16)
                    progressBlock
                    if isStuck {
                        hairline.padding(.vertical, 16)
                        stuckBlock
                    }
                    Color.clear.frame(height: 16)
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
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
        VStack(alignment: .leading, spacing: 6) {
            Text("让你的 agent 入住")
                .font(.notoSerifSC(size: 21, weight: .medium))
                .foregroundStyle(Color.cinFg)
            // Sets expectations: deep bootstrap is slow, that's by design.
            // User can close the app — agent keeps running on its runtime.
            Text("深度 bootstrap 通常 30–60 分钟。\n可以关掉 app，agent 在它自己那边继续。")
                .font(.notoSerifSC(size: 11.5))
                .foregroundStyle(Color.cinSub)
                .lineSpacing(2)
        }
        .padding(.top, 12)
    }

    // MARK: - Steps

    private var stepsBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("WHAT TO DO")

            stepCard(
                index: "01",
                title: "把 skill 给你的 agent",
                description: "把这个 URL 喂给它，让它按里面的步骤做。",
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
                description: "写身份卡、种记忆、打招呼，约 1–2 分钟。",
                primaryLabel: nil,
                primaryAction: nil
            )
        }
    }

    private func sectionLabel(_ title: String) -> some View {
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
        HStack(alignment: .top, spacing: 14) {
            Text(index)
                .font(.newsreader(size: 20))
                .foregroundStyle(Color.cinAccent1)
                .frame(width: 26, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.notoSerifSC(size: 14, weight: .medium))
                    .foregroundStyle(Color.cinFg)
                Text(description)
                    .font(.notoSerifSC(size: 12))
                    .foregroundStyle(Color.cinSub)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let codeBlock {
                    Text(codeBlock)
                        .font(.dmMono(size: 9.5))
                        .foregroundStyle(Color.cinFg)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(Color.cinAccent1Soft)
                        .padding(.top, 4)
                }

                if let primaryLabel, let primaryAction {
                    Button(action: primaryAction) {
                        Text(primaryLabel)
                            .font(.dmMono(size: 9, weight: .medium))
                            .foregroundStyle(Color.cinAccent1)
                            .kerning(2.5)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Progress

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("AGENT PROGRESS")
                .padding(.bottom, 2)

            // Order matches the new memories-first bootstrap: memory
            // garden grows first; identity is DERIVED from memories;
            // first message comes last as the agent signals "I'm here".
            progressRow(
                label: "Memory garden",
                done: bootstrap.status.memoriesCount >= 5,
                detail: bootstrap.status.memoriesCount == 0
                    ? (bootstrap.status.agentConnected ? "starting…" : "—")
                    : (bootstrap.status.agentMessagesCount >= 1
                        ? "\(bootstrap.status.memoriesCount) cards"
                        : "\(bootstrap.status.memoriesCount) cards · 还在长")
            )
            progressRow(
                label: "Identity card",
                done: bootstrap.status.identityWritten,
                detail: bootstrap.status.identityWritten ? "derived" : "—"
            )
            progressRow(
                label: "First message",
                done: bootstrap.status.agentMessagesCount >= 1,
                detail: bootstrap.status.agentMessagesCount >= 1
                    ? "delivered"
                    : (bootstrap.status.identityWritten ? "soon…" : "—")
            )
        }
    }

    private func progressRow(label: String, done: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(done ? Color.cinAccent1 : Color.cinLine, lineWidth: 1)
                    .frame(width: 12, height: 12)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(Color.cinAccent1)
                }
            }
            Text(label)
                .font(.notoSerifSC(size: 12.5))
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
            sectionLabel("STUCK?")
            Text("已经 5 分钟没动静。把下面这段发给你 agent，让它自检卡在哪一步：")
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
        我给了你 IO 的 skill (\(Self.skillURL)) 和一个 MCP 连接 (\(mcpString))，但 bootstrap 没进展。请按以下顺序自检并告诉我每一步结果：

        1. 你 fetch 过那个 skill URL 吗？把它的标题和第一节的标题原文复述给我（验证你真读了）。
        2. 你输出 Step 0 三行了吗？现在重新输出：
           - EARLIEST MESSAGE I CAN FIND FROM THIS USER: <ISO date | NONE>
           - NAME I'VE BEEN CALLED IN PRIOR CHATS: <name | NONE>（不能是 runtime label）
           - APPROXIMATE MEMORABLE MOMENTS I CAN RECALL: <integer | 0>
        3. 你的 MCP 连接里有 feedling_* 工具吗？调一次 feedling_chat_get_history 看响应（401 / 500 / 别的？）。
        4. 你目前卡在哪一步：fetch skill / Step 0 verify / Pass 1 唤醒 / Pass 2 清点 / Pass 3 落卡 / Pass 4 对账 / identity 派生？
        5. 如果有任何错误，把错误原文贴回来。

        别只回"我在做了"——具体到每一步的状态。
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
