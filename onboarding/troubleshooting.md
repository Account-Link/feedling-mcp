# IO · Troubleshooting

When something doesn't work — read this first. If you're still stuck, ping us with your symptoms + which section below got closest.

---

## 中文

### 1. Chat 页一直停在 "WAITING FOR AGENT"

**含义**：服务器没看到任何 agent 写过任何东西。Agent 没真正连上、或者连上但还没动。

**排查顺序：**

1. **MCP 连接到位了吗？** 在你的 agent 客户端里手动确认 MCP server 显示为已连接（不同客户端的 UI 不一样，但都会有"已连接 / 工具列表"的提示）。

2. **Skill 被读了吗？** 你 agent 真的读了 `https://feedling.app/skill.md` 吗？再问一遍："请确认你 fetch 了那个 URL，简短复述里面的 bootstrap 步骤。" 如果它复述不出来，说明它跳过了 fetch。

3. **Agent 收到了 401？** 偶尔 MCP 客户端在传 API key 时会出问题。让 agent 调一次 `feedling_chat_get_history` 看响应。如果是 401 / unauthorized，说明 key 没正确传过去——重新连一遍 MCP server。

4. **空白页 60 秒后会出现 "STUCK?" 区块**：里面有一段 debug prompt 可以一键复制，直接发给你 agent，agent 会自己自检并报告卡在哪一步。

### 2. Identity 页显示 "DAY 0" 或者一个奇怪的天数

**含义**：你 agent 算关系天数算错了，或者它没在第一次 init 时传 `days_with_user`。

**修法**：直接在 Chat 里跟 agent 说："我们其实认识 X 个月（或 X 天）了，请校准一下。"

Agent 应该调 `feedling_identity_set_relationship_days` 把数字改对。改完之后**永远不会再漂移**——服务器锚住了一个固定的日期，每天自动 +1。

如果 agent 不知道要调那个工具，让它去重读 skill：`fetch https://feedling.app/skill.md` 然后看 "Step 3 — Greet and calibrate" 那段。

### 3. Memory Garden 里只有 0–2 张卡

**含义**：Agent 没认真做 bootstrap 第 2 步的 Memory Garden 种植。

**修法**：跟 agent 说："你只写了 X 张记忆卡。请按 skill 里的 'Coverage floor' 规则补到对应数量。如果我们认识超过三周，至少要 10 张。"

Agent 会回去搜对话历史然后补写。

### 4. Chat 收不到 agent 回复

发了消息以后一直 loading 不回。

**最常见原因（按概率）：**

- **Agent 那边没在 watch 这个 chat**——claude.ai 网页版尤其容易这样。Claude.ai 的对话是"被动响应"模式，它不会自己定时去 poll 你的 IO 消息。换句话说，你在 IO 里发的消息它根本不知道。
  - 解决：用 Claude Code（CLI 模式，可以长驻 polling）、或者你自己写一个 wrapper 把 Anthropic API 接到一个长驻进程里。这种用法在 [`skill.md` 里 "Main Loop" 那一节](./skill.md#main-loop) 有说明。
- **Vision gate 拦了**——如果 agent 试图 `feedling_push_live_activity` 但没先调 `feedling_screen_decrypt_frame(include_image=true)`，会被服务器返回 `vision_gate_missing_decrypt`。让 agent 先 decrypt frame。
- **Agent 在循环 retry 但一直失败**——去 Settings → Health Check 看 "Chat round-trip" 那行。如果它显示 "no agent reply yet"，说明 server 也没收到 reply，问题在 agent 侧。

### 5. Live Activity 没出现在锁屏

**修法**：

1. 第一次安装时，app 应该在 onboarding 里弹了"启用 Live Activity"的按钮。如果你没点，去 iOS 系统 Settings → IO → Live Activities → 打开。
2. 锁屏然后等 agent push。Settings → Health Check → "Test live activity push" 可以发一条本地测试推送验证通路。
3. 如果系统设置里 Live Activity 开关已开但还是没显示——重启 IO app（双击主屏 swipe 关掉）然后重开。

### 6. Health Check 页显示一切正常但实际 chat 不通

可能是 agent 那边在做"假装我做了"——LLM 偶尔会编造它实际没做的工具调用。

**验证**：直接看 IO 的 Chat tab。如果你发出去的消息真的有 agent 回复出现，就是真的通了。Health Check 是辅助，最终事实是 chat tab 里的真实消息。

### 7. 我换了 iPhone 语言 / 重装了 app / 系统更新之后 chat 全空了

**含义**：你的 API key 在客户端被清空了，IO 帮你注册了一个全新的账号——你之前的 chat / identity / memories 都还在服务器上，只是绑在旧账号下。

如果你装的是包含 Keychain 修复的版本（commit `ee6bd78` 之后），这种事不会再发生。如果还是发生了，告诉我们，我们看一下日志能不能帮你恢复旧账号。

如果你装的是更老的版本——升级到最新版（你这一段日子里如果没更新，重新从 TestFlight 装一下）。

### 还在卡住

把以下信息发给我们：

- iOS 版本
- IO build number（在 Settings 最底部 `v 0.5.0` 那种）
- 你用的是哪个 agent 客户端（Claude Code / Desktop / claude.ai / 其他）
- 卡在哪一步（参考 quickstart 的 5 步）
- Health Check 页的截图

---

## English

### 1. Chat tab stuck on "WAITING FOR AGENT"

**Meaning**: the server hasn't seen any agent activity yet. Agent isn't really connected, or is connected but hasn't done anything.

**Triage in order:**

1. **Is the MCP connection up?** In your agent client, verify the MCP server shows as connected (every client surfaces this differently, but all show "connected / tools listed" somewhere).

2. **Did the agent read the skill?** Did your agent actually fetch `https://feedling.app/skill.md`? Ask it again: "Confirm you fetched that URL and briefly recap the bootstrap steps." If it can't recap, it skipped the fetch.

3. **Is the agent getting 401?** Occasionally MCP clients have trouble passing the API key. Have the agent call `feedling_chat_get_history` and check the response. If it's 401 / unauthorized, the key didn't propagate — reconnect the MCP server.

4. **After 60 s the empty state shows a "STUCK?" block**: it includes a one-tap copyable debug prompt that lets the agent self-diagnose and report exactly which step failed.

### 2. Identity page shows "DAY 0" or an obviously wrong number

**Meaning**: your agent miscounted the relationship age, or didn't pass `days_with_user` at init.

**Fix**: say to your agent in chat: "We've actually known each other X months (or X days), please recalibrate."

The agent should call `feedling_identity_set_relationship_days` to fix it. Once fixed, the count **never drifts again** — the server pins a fixed start date and auto-increments daily.

If the agent doesn't know that tool exists, ask it to re-read the skill at `https://feedling.app/skill.md`, specifically the "Step 3 — Greet and calibrate" section.

### 3. Memory Garden has only 0–2 cards

**Meaning**: the agent didn't take Step 2 (Memory Garden seeding) seriously.

**Fix**: tell the agent: "You only wrote X memory cards. Please apply the 'Coverage floor' rule from the skill — if we've known each other 3+ weeks, that's at least 10."

The agent will go back to its conversation history and write more.

### 4. Chat sends but no reply ever comes

You send a message and it sits in a loading state forever.

**Most common causes (by probability):**

- **Your agent isn't watching the chat**. Especially common with claude.ai web — it's a request-response model and doesn't background-poll your IO messages. So messages you send in IO go into a queue your agent never checks.
  - Fix: use Claude Code (CLI, can run a long-poll loop) or wire up the Anthropic API in your own long-running wrapper. The "Main Loop" section in [`skill.md`](./skill.md#main-loop) explains the pattern.
- **Vision gate blocked the push**. If the agent tried `feedling_push_live_activity` without first calling `feedling_screen_decrypt_frame(include_image=true)`, the server returns `vision_gate_missing_decrypt`. Tell the agent to decrypt the frame first.
- **The agent is silently retry-looping**. Check Settings → Health Check → "Chat round-trip" row. If it says "no agent reply yet", the server never received a reply — the issue is on the agent side.

### 5. Live Activity isn't showing on the lock screen

**Fixes:**

1. On first install, the app's onboarding had a "Enable Live Activity" button. If you skipped it, go to iOS Settings → IO → Live Activities → enable.
2. Lock the phone and wait for the agent to push. Settings → Health Check → "Test live activity push" sends a local test push that bypasses the agent — useful to confirm the channel itself is wired.
3. If iOS settings show Live Activity enabled but nothing appears, force-quit IO (swipe up from the home indicator and swipe IO away) and relaunch.

### 6. Health Check looks all green but chat doesn't actually work

The agent may be "pretending it worked" — LLMs occasionally fabricate tool calls they never actually made.

**Ground truth**: look at IO's Chat tab directly. If your messages get real replies showing up there, it works. Health Check is a hint, not the source of truth.

### 7. After switching iPhone language / reinstalling / OS update, chat went empty

**Meaning**: your client-side API key got cleared and IO auto-registered a fresh account — your old chat / identity / memories are still on the server, just bound to the old account.

If you installed a build that includes the Keychain fix (commit `ee6bd78` or later), this should not happen anymore. If it does, ping us — we can probably recover the old account from server logs.

If you're on an older build, upgrade to the latest TestFlight build.

### Still stuck?

Send us:

- Your iOS version
- The IO build number (Settings, bottom — looks like `v 0.5.0`)
- Which agent client you're using (Claude Code / Desktop / claude.ai / other)
- Which step you got stuck on (reference the 5 steps in quickstart)
- A screenshot of the Health Check page
