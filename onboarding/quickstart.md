# IO · Quickstart

Get IO running on your phone, with your own AI agent inside, in about 5 minutes.

---

## 中文

### 你需要什么

- 一台 iPhone（iOS 16.2 或更高）
- 一份 Anthropic API key（[console.anthropic.com](https://console.anthropic.com)），或者你已经在用 Claude Code / Claude Desktop / 其他支持 MCP 的 agent 客户端
- 大约 5 分钟

### 5 步

**1. 安装 IO**

通过 TestFlight 邀请链接安装。打开后，app 会自动注册一个云端账号，你不用做任何事——等几秒看到 Chat 页面就好。

**2. 拿到你的 MCP 连接字符串**

打开 app → Settings → 你会看到 `MCP String` 那一行。点 `COPY ↗`，整段复制下来。它长这样：

```
claude mcp add feedling --transport sse "https://mcp.feedling.app/sse?key=…"
```

**3. 把 skill 喂给你的 agent**

把这个链接发给你的 agent，让它读：

```
https://feedling.app/skill.md
```

具体怎么"发给 agent"看你用什么客户端：

- **Claude Code**：跑 `claude` 然后说 "请读 https://feedling.app/skill.md 这份 skill 然后跟着做 IO 的 bootstrap。先连接以下 MCP 服务器：" 然后粘贴上一步复制的 MCP String。
- **Claude Desktop**：在配置文件里加上 MCP server，然后开启对话说 "请读 https://feedling.app/skill.md 然后做 bootstrap。"
- **claude.ai 网页**：把 MCP server 加为 Connector，然后在新对话里说同样的话。
- **其他 MCP 客户端**：先连 MCP server，然后让 agent 读 skill URL。

**4. 等**

打开 IO app → Chat 页。你会看到一个进度清单：

- ⏳ Identity card
- ⏳ Memories planted (0 / 3+)
- ⏳ First message

Agent 会依次完成这三件事，大约 1–2 分钟。期间它会写身份卡、种记忆、然后给你发第一条消息。第一条消息里它会问你"我们认识多少天了，对吗？"——回答它就好。

**5. 验收**

四件事到位就算 setup 成功：

- [ ] **身份卡**：Identity tab 上能看到你 agent 的名字、5 维雷达图、自我介绍
- [ ] **记忆花园**：Garden tab 里至少 3 张记忆卡片
- [ ] **第一次回复**：Chat tab 看到 agent 的开场消息（包含天数确认问题）
- [ ] **天数对了**：你回答天数确认之后，刷新 Identity 页，"DAY X" 数字应该是你说的那个

四件齐全 → setup 完成。开聊就行。

### 出问题了？

看 [`troubleshooting.md`](./troubleshooting.md)。

---

## English

### What you need

- An iPhone (iOS 16.2 or higher)
- An Anthropic API key from [console.anthropic.com](https://console.anthropic.com), or an existing Claude Code / Claude Desktop / other MCP-capable agent client
- About 5 minutes

### 5 steps

**1. Install IO**

Install via the TestFlight invite link. On first launch, IO auto-registers a cloud account — you don't have to do anything. Wait a few seconds for the Chat tab to appear.

**2. Grab your MCP connection string**

Open the app → Settings → look for the `MCP String` row. Tap `COPY ↗`. It looks like:

```
claude mcp add feedling --transport sse "https://mcp.feedling.app/sse?key=…"
```

**3. Feed the skill to your agent**

Send this URL to your agent and ask it to read it:

```
https://feedling.app/skill.md
```

How to "send to your agent" depends on your client:

- **Claude Code**: run `claude`, then say "Please fetch https://feedling.app/skill.md and follow the IO bootstrap. First connect the following MCP server:" then paste the MCP String from step 2.
- **Claude Desktop**: add the MCP server in your config, then in a new chat say "Please read https://feedling.app/skill.md and run the bootstrap."
- **claude.ai web**: add the MCP server as a Connector, then in a new chat say the same.
- **Any other MCP client**: connect the MCP server first, then ask the agent to read the skill URL.

**4. Wait**

Open IO → Chat tab. You'll see a progress checklist:

- ⏳ Identity card
- ⏳ Memories planted (0 / 3+)
- ⏳ First message

Your agent will tick these off in order, ~1–2 minutes total. It writes the identity card, plants the Memory Garden, then sends its first chat message. That first message will ask "we've known each other ~N days, right?" — just answer.

**5. Acceptance check**

Setup is done when all four are true:

- [ ] **Identity card** — the Identity tab shows your agent's name, 5-axis radar, and self-introduction
- [ ] **Memory Garden** — the Garden tab has at least 3 cards
- [ ] **First message** — the Chat tab shows your agent's opening message with a days-confirmation question
- [ ] **Days are right** — after you answer the days question, refresh the Identity tab; the "DAY X" number should match what you said

All four green → setup complete. Just chat.

### Something went wrong?

See [`troubleshooting.md`](./troubleshooting.md).
