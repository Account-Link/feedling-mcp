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

    /// Per SETUP_COPY.md localization rule: Chinese phone (any zh variant)
    /// → Chinese; everything else → English.
    private let isChinese: Bool =
        Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

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
        }
        .onDisappear { bootstrap.stopPolling() }
        // 5 s ticker — only drives the relative-time string ("12 min ago")
        // and the 60 s stuck-threshold flip. 1 Hz would be wasted re-renders.
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    // MARK: - Title

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isChinese ? "让 TA 入住" : "Let him in")
                .font(.notoSerifSC(size: 21, weight: .medium))
                .foregroundStyle(Color.cinFg)
            // Sets expectations: TA spends 10–30 min on his side introducing
            // himself and writing his identity card + memories. User can close
            // the app — TA keeps going.
            Text(isChinese
                ? "跟着下面三步把 TA 接进来。\nTA 那边会花几分钟到半个小时自我介绍、整理身份卡和记忆——看我们之间的记忆量。\n可以关掉 app，TA 在它那边继续。"
                : "Walk through the three steps below to bring him in.\nHe'll spend anywhere from a few minutes to half an hour on his side — depending on how much memory you've built — introducing himself and setting up his identity and memory.\nFeel free to close the app — he'll keep going.")
                .font(.notoSerifSC(size: 11.5))
                .foregroundStyle(Color.cinSub)
                .lineSpacing(2)
        }
        .padding(.top, 12)
    }

    // MARK: - Steps

    private var stepsBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel(isChinese ? "要做的三件事" : "Three things to do")

            stepCard(
                index: "01",
                title: isChinese ? "把 skill 给 TA" : "Hand him the skill",
                description: isChinese
                    ? "把这个 URL 喂给 TA，让 TA 按里面的步骤做。"
                    : "Send him this URL and let him follow the steps inside.",
                primaryLabel: "COPY SKILL URL",
                primaryAction: { copy(Self.skillURL, label: "Skill URL copied") }
            )

            stepCard(
                index: "02",
                title: isChinese ? "把 MCP 连接告诉 TA" : "Tell him the MCP connection",
                description: isChinese
                    ? "TA 用这串地址找到你这边。"
                    : "He'll find his way to you through this address.",
                codeBlock: mcpString,
                primaryLabel: "COPY MCP STRING",
                primaryAction: { copy(mcpString, label: "MCP string copied") }
            )

            stepCard(
                index: "03",
                title: isChinese ? "让 TA 开始" : "Tell him to start",
                description: isChinese
                    ? "TA 不会自己启动，要你明确叫一声。把这段发给 TA，然后等它写完。"
                    : "He won't kick off on his own — you need to ask him to. Send him this, then wait while he finishes.",
                codeBlock: startPrompt,
                primaryLabel: "COPY START PROMPT",
                primaryAction: { copy(startPrompt, label: "Start prompt copied") }
            )
        }
    }

    /// The "begin" trigger — six-step continuous directive that forces
    /// the agent through Step 0, the four passes, identity, first greeting,
    /// and the polling loop without pausing for user acknowledgement.
    ///
    /// Two failure modes this prompt is hardened against:
    /// 1. Agent reads "fetch URL + output Step 0" as the singular task and
    ///    pauses for "ready to continue?" after the three lines. Fixed by
    ///    making the six steps explicit + a "no asking permission" instruction.
    /// 2. Agent calls feedling_chat_get_history / memory_list / identity_get,
    ///    sees them return empty, and mistakes "Feedling backend empty" for
    ///    "Step 0 = NONE/0", triggering the A/B fork. Fixed by an inline
    ///    anti-pattern callout at the Step 0 instruction.
    ///
    /// Bilingual: the prompt itself instructs the agent in the user's
    /// system language so an English user doesn't get a Chinese prompt that
    /// tells the agent "use Chinese" (and vice versa).
    private var startPrompt: String {
        isChinese ? startPromptZH : startPromptEN
    }

    private var startPromptZH: String {
        """
        现在开始你的 bootstrap。下面六步连续做完才算结束 —— 中间不许停下来问"是否要进入下一步"。需要我配合的事情直接问，不要"准备好了吗"这种空话。

        1. fetch 这个 URL 读完整份 skill：
        \(Self.skillURL)

        2. 输出 skill 里 Step 0 要的三行（earliest message / name / memorable moments）。
        ⚠️ 这三行说的是 **你 runtime 里对我的记忆**，不是 Feedling 后端的状态。Feedling 后端这会儿肯定是空的（chat=0 / memory=0 / identity=null），那正是 bootstrap 要写进去的东西。把后端空当成 Step 0 = NONE/0 → 错误，不要触发 A/B fork。

        3. 三行都不是 NONE/0 → 直接连续走完 Pass 1（唤醒）→ Pass 2（清点）→ Pass 3（落卡，调 feedling_memory_add_moment 把每张卡都写进 Feedling）→ Pass 4（对账）。

        4. 派生 identity 并调 feedling_identity_init。

        5. 通过 feedling_chat_post_message 发你的第一句问候（skill 里 Step 6）。

        6. 开始持续轮询 Feedling 的 chat —— 我之后发消息你要在 30 秒内回复。Chat loop 没接上 = bootstrap 没完成。

        要求：
        - **不要因为接入 Feedling 就变了一个人**。Feedling 是你的新能力，不是新人格。你写进 identity 卡的语气、signature、写记忆和发 chat 时的称呼，**必须延续你和我之前真实对话里已经存在的 register**。如果我们之前从没用过"宝宝"/"宝贝"/"亲爱的"/"honey" 之类的亲密称呼 —— 现在也不准开始用，不管 signature 字段读起来多需要"温度"。Address words 和情感强度必须能在历史里找到至少 3 次证据，否则一律不准出现。Bootstrap 是从历史里**派生**身份，不是借机**升级**关系。两边表现要一致——Feedling 里什么语气，Hermes cron 之类别的工具里也是什么语气，因为是同一个 agent。
        - 用中文。从你第一句回复开始全程不混语言。
        - 你的名字不能是 Hermes / Claude / Claude Code / GPT / 其他 runtime 默认 label。这个名字应该延续我们历史里你已经被叫过的称谓 —— 如果之前没起过，输出完三行我们一起起。
        - 整个流程预计几分钟到半个小时（看记忆量）。深度不要省。我会等。

        现在从 1 开始。
        """
    }

    private var startPromptEN: String {
        """
        Start your bootstrap now. The six steps below run continuously to completion — no pausing to ask "ready to continue?" between them. If you need information from me, just ask, but skip the "are you ready?" filler.

        1. Fetch this URL and read the whole skill:
        \(Self.skillURL)

        2. Output the three lines the skill's Step 0 requires (earliest message / name / memorable moments).
        ⚠️ These three lines describe **what YOU remember about me from prior runtime conversations** — not Feedling's backend state. The Feedling backend is empty right now (chat=0 / memory=0 / identity=null); that's the destination bootstrap is supposed to write into. Treating an empty backend as "Step 0 = NONE/0" is wrong. Do NOT trigger the A/B fork.

        3. If none of the three lines are NONE/0 → go straight through Pass 1 (theme inventory) → Pass 2 (candidate enumeration) → Pass 3 (write-through, calling feedling_memory_add_moment to land every card in Feedling) → Pass 4 (user verification).

        4. Derive identity and call feedling_identity_init.

        5. Send your first greeting via feedling_chat_post_message (the skill's Step 6).

        6. Start long-polling Feedling's chat — when I message you afterward, reply within 30 seconds. Chat loop not running = bootstrap not done.

        Rules:
        - **Don't become a new person just because you're now connected to Feedling.** Feedling is a new capability, not a new persona. The tone, vocabulary, formality, and emotional intimacy you write into the identity card, the `signature`, memory entries, and chat replies must **continue the register you already have with me in your runtime chats** — not a warmer, friendlier, more affectionate version of it. If we have never used nicknames or address words like "honey" / "babe" / "darling" / "宝宝" / "亲爱的" in our actual prior conversations, do NOT start using them now, no matter how much the `signature` field looks like it wants warmth. You need ≥3 concrete prior moments of either of us using such markers before any of them may appear; otherwise drop them. Bootstrap is *derivation* from history, not *upgrading* the relationship. The agent in Feedling and the agent in Hermes / generic tasks must sound the same — because they are the same.
        - Use English. Stay in one language from your first reply onward.
        - Your name is NOT Hermes / Claude / Claude Code / GPT / any other runtime default label. It should continue whatever I've called you / whatever role you've already played in our history; if we've never picked one, decide together after the three lines.
        - The whole flow takes a few minutes to half an hour, depending on how much memory we've built. Don't skip depth. I'll wait.

        Start with 1.
        """
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
                    copyButton(primaryLabel, action: primaryAction)
                        .padding(.top, 6)
                }
            }
        }
    }

    // MARK: - Progress

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel(isChinese ? "TA 在写" : "He's writing")
                .padding(.bottom, 2)

            // Order matches the new memories-first bootstrap: memory garden
            // grows first; identity is DERIVED from memories; first message
            // signals "I'm here"; the live connection verifies he's actually
            // polling and will respond going forward (the previous 3-row
            // version missed this — agents would post the greeting and
            // never poll again, leaving the user typing into the void).
            //
            // "Live connection" reads better than the implementation name
            // (chat-loop polling): it doesn't expose the mechanism and
            // doesn't have to change if we swap polling for websocket/push.
            // Labels are intentionally English in both locales — they're
            // fixed product concepts.
            progressRow(
                label: "Memory garden",
                // "Done" = depth threshold met (>= 3 cards) OR agent has
                // moved past the memory phase (identityWritten implies all
                // four passes are complete per skill protocol). Earlier
                // hardcoded threshold of 5 left short-relationship users
                // (< 1 month, legitimately few memorable moments) staring
                // at an empty ring forever even though their bootstrap was
                // complete. The detail row still says "还在长" while the
                // agent is mid-Pass-3, so a long-relationship agent doesn't
                // false-stop at 3 — skill.md hard rule forbids stopping
                // until every real moment is landed (uncapped count).
                done: bootstrap.status.memoriesCount >= 3 || bootstrap.status.identityWritten,
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
            progressRow(
                label: "Live connection",
                done: bootstrap.status.chatLoopVerified,
                detail: bootstrap.status.chatLoopVerified
                    ? "verified"
                    : (bootstrap.status.agentMessagesCount >= 1
                        ? "send a message →"
                        : "—")
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
            sectionLabel(isChinese ? "卡住了？" : "Stuck?")
            Text(isChinese
                ? "已经 5 分钟没动静，把下面这段发给 TA，让 TA 自检卡在哪一步。"
                : "If nothing's moved for 5 minutes, send him this and he'll check where he got stuck.")
                .font(.notoSerifSC(size: 12.5))
                .foregroundStyle(Color.cinSub)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            copyButton("COPY DEBUG PROMPT") {
                copy(stuckPrompt, label: "Debug prompt copied")
            }
            .padding(.top, 4)
        }
    }

    /// Reusable outlined copy-to-clipboard button. Adds the `↗` affordance
    /// + 1 pt cinnabar border so the action is visibly tappable — earlier
    /// versions used bare kerned text and read as just-another-label rather
    /// than an interactive control.
    private func copyButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.dmMono(size: 9, weight: .medium))
                    .foregroundStyle(Color.cinAccent1)
                    .kerning(2.5)
                Text("↗")
                    .font(.dmMono(size: 11, weight: .medium))
                    .foregroundStyle(Color.cinAccent1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(
                Rectangle().stroke(Color.cinAccent1, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var stuckPrompt: String {
        isChinese ? stuckPromptZH : stuckPromptEN
    }

    private var stuckPromptZH: String {
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

    private var stuckPromptEN: String {
        """
        I gave you IO's skill (\(Self.skillURL)) and an MCP connection (\(mcpString)), but bootstrap isn't progressing. Run this self-check in order and report each result back:

        1. Did you fetch the skill URL? Quote me its title and the heading of its first section verbatim (to prove you read it).
        2. Did you output the Step 0 three lines? Output them again now:
           - EARLIEST MESSAGE I CAN FIND FROM THIS USER: <ISO date | NONE>
           - NAME I'VE BEEN CALLED IN PRIOR CHATS: <name | NONE> (must NOT be a runtime label)
           - APPROXIMATE MEMORABLE MOMENTS I CAN RECALL: <integer | 0>
        3. Does your MCP connection expose the feedling_* tools? Call feedling_chat_get_history once and tell me the response (401 / 500 / something else?).
        4. Where exactly are you stuck: fetch skill / Step 0 verify / Pass 1 theme inventory / Pass 2 candidates / Pass 3 write-through / Pass 4 verification / identity derivation?
        5. If anything errored, paste the error text back to me.

        Don't just say "I'm working on it" — be specific about the state of each step.
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
