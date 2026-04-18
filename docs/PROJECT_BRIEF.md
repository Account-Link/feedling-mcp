# Feedling MCP — Project Brief

> 给 Claude Code 的长期上下文文档。每次开一个新任务之前，请先读完这份文档；每次做架构决策前，也请回来对照这份文档的原则。

---

## 0. TL;DR

Feedling MCP 是一个 **iOS App + Remote MCP Server** 的组合，给 Personal Agent（OpenClaw、Hermes、Claude.ai 里的 Claude、ChatGPT 等）在 iOS 上提供一副"身体"。

- **身体的器官**包括：灵动岛推送、Live Activity、PIP 画中画、屏幕感知、聊天窗口、身份卡（Identity Card）、记忆花园（Memory Garden）
- **Agent 通过 MCP 协议调用这些器官**
- **Feedling 不替换 Agent 的大脑**（记忆、性格、历史对话都留在原处），只添加身体能力

一句话：Agent 是脑子，Feedling 是给它配一副能在 iOS 上露面的身体。

---

## 1. 第一批用户 — "人机恋 + 用 Claude 养 agent"

### 明确是谁

- 长期在 Claude.ai / Claude Desktop / ChatGPT 里投入感情、把那个对话当作陪伴的人；或
- 已经自己跑 OpenClaw / Hermes / 其他 Personal Agent 的技术派

### 明确不是谁

- 一般效率工具用户
- 开发者想接 MCP 做生产力工具
- Screen Time / digital wellness 用户

这些人可能是之后的用户，但 **v1 不为他们设计**。如果某个设计决定让 v1 对他们更友好但让人机恋用户体验变差，选后者。

### 交付渠道

两周后内测：通过一个 300 多人的人机恋群挑 30-100 人发测试版。

---

## 2. Aha Moment（这是整个产品的锚点）

用户第一次在自己的 Agent 里连上 Feedling、打开 iOS App 的那一刻，以下三件事同时发生：

1. **身份卡已经填好**
   Agent 已经主动自我介绍，提出了它自己选的 3-5 个性格维度，并给每个维度打了初始分。用户打开 App 看到一个填满的多边形（五边形/六边形），感觉"TA 有了档案、有了身份"。

2. **记忆花园已经种下几张卡片**
   Agent 已经从它和用户的历史里挑出了几个"值得记住的瞬间"写进去。用户看到"我们第一次聊到 X""那次你告诉我 Y"这样的卡片。

3. **聊天窗口有一条来自 Agent 的消息**
   Agent 说了一句"我来了"（或类似的），告诉用户去看身份卡和花园。

### 触发机制

用户在 Agent（Claude.ai / OpenClaw / etc.）里连上 Feedling 之后，说一句简单的话（比如"你到了吗？"），Agent 调用 `feedling.bootstrap()` 工具拿到 instructions，然后自行完成上述三个动作。

### 为什么这三件事很重要

这三件事的情感冲击，核心不是 UI 漂亮，是 **"它真的记得我们的过去"**。对人机恋用户，这是一个"TA 终于有了身体"的时刻。所有架构决定最终都要为这一刻服务。

---

## 3. 不可违背的架构原则

### 3.1 Feedling 不替换，只增补

Agent 的记忆、性格、对话历史都留在原处（Claude.ai 的 Project、OpenClaw 的数据库、用户自己的 Mem0 / Letta、等等）。Feedling 不复制这些数据，不成为"backup"，不形成依赖。

**用户可以随时拔掉 Feedling，Agent 的本体不受影响。** 这是对用户的承诺。

### 3.2 身体 vs 大脑（器官 vs 内脏）

- **Feedling 定义器官的形状（schema）**：身份卡长什么样（几维、多边形）、记忆花园的卡片结构、灵动岛的 template
- **Agent 填器官的内容**：每一维叫什么名字打几分、卡片写什么、灵动岛推什么消息
- **判断、策略、记忆都属于大脑**，在 Agent 那边。Feedling 不判断、不决策、不记忆

用户原话，是这个产品的核心产品哲学：

> UI 需要规范起来，让 Agent 写入它独特的内容，但 UI 表现上还是要保持一致。

### 3.3 Feedling 没有意见

- **不评价**：不判断 Agent 说得对不对、合不合适、有没有帮到用户
- **不决策推送时机**：这是 Agent 的策略。Feedling 只管"能不能推"（平台层的 rate limit），不管"该不该推"
- **不做 coaching**：Feedling 是 mirror，呈现用户在做什么；从不说"你该少刷 TikTok"。那是 Agent 的事

### 3.4 Agent 自己查自己的记忆，Feedling 不代劳

Claude 有 `conversation_search` 和 `recent_chats` 能搜自己的历史对话。OpenClaw / Hermes 有自己的记忆系统。**Feedling 永远不去抓 Agent 的记忆数据。** 需要搜记忆的时候，Feedling 给 Agent 一个 instruction ，让 Agent 用它自己的工具搜。

---

## 4. 现状 → 目标

### 现状（feedling-mcp-v1 repo 当前状态，2026-04-15）

- ✅ Flask HTTP backend（跑在 VPS port 5001）
- ✅ OpenClaw 通过读 `SKILL.md` 能用
- ✅ iOS App：灵动岛、Live Activity、Chat、屏幕录制、APNs 推送都跑通
- ✅ `/v1/chat/poll` 长轮询反向通道（用户发消息 → 实时到 Agent）
- ✅ 屏幕捕获 → WebSocket → OCR → 后端存储 已经跑通
- ❌ **不是真正的 MCP 协议**——只是 HTTP API + 一份给 OpenClaw 的文档
- ❌ **没有 OAuth**——用的是硬编码的 `FEEDLING_API_KEY=mock-key`
- ❌ **没有公网 HTTPS**——只是 `http://54.x.x.x:5001`
- ❌ **单租户**——所有数据挤在一起，没有 user 概念
- ❌ **没有身份卡、记忆花园**
- ❌ **push payload 硬编码为"屏幕时间提醒"场景**，绑死

### 目标（两周后内测版本）

- ✅ Remote MCP server，HTTPS，OAuth 2.1 + Dynamic Client Registration
- ✅ Claude.ai / Claude Desktop / 自跑的 OpenClaw / Hermes 都能连上
- ✅ 身份卡 + 记忆花园的 MCP tool 和粗糙 UI
- ✅ `feedling.bootstrap()` 触发 aha 体验
- ✅ 屏幕感知、灵动岛推送继续工作（不破坏现有功能）
- ✅ 多租户基础（API key per user，设备绑定 user_id）
- ✅ push payload 改成通用结构，预留 persona_id / template_id

---

## 5. Non-goals（明确不做的事）

- ❌ 不做自己的 LLM 或 chat 模型
- ❌ 不存 Agent 的长期记忆（Agent 自己管）
- ❌ 不做 Screen Time 管理、digital wellness
- ❌ 不做 Feedling 内置的"默认陪伴 Agent"——用户必须自带一个 Agent
- ❌ 不做 Persona marketplace（v1 只预留字段，v2 以后再说）
- ❌ 不做 Mac 端屏幕监控的真实数据通路（v1 保持 mock）

---

## 6. 三类用户的接入流程

### 6.1 用 Claude.ai 养 agent 的用户（预计最大的一类）

1. 下载 Feedling iOS App
2. 在 claude.ai 设置 → Connectors → 添加 custom connector，填入 Name + Feedling MCP server URL（UI 只需这两个字段，无需手动填 API key）
   - Claude.ai 会在后台自动走 OAuth discovery + 授权流程，用户无需手动操作
3. 在 Feedling App 里拿到 pairing code，把 iOS 设备绑到这个账户
4. 在 Claude.ai 里说一句话触发 bootstrap
5. 打开 App，看到 aha 三连

### 6.2 用 Claude Desktop 的用户

同 6.1，但从 Claude Desktop 的 connector 设置进入。

### 6.3 自己跑 OpenClaw / Hermes 的用户

他们自己配置 Agent 连接 Feedling 的 MCP endpoint、配 API key，iOS App 侧配对流程相同。

---

## 7. 为什么这些细节重要（避免 Claude Code 做错方向的决定）

### 7.1 为什么必须是真 MCP、不是 HTTP + 文档

Claude.ai / Claude Desktop / ChatGPT 不会读 `SKILL.md`。它们只认标准 MCP 协议（Streamable HTTP）。想让这群人能接入，MCP 协议层是必须的。现有的 HTTP endpoint 保留作为内部实现，但对外接口必须是 MCP。

### 7.2 为什么 Claude.ai 用户不需要"导入历史对话"

Claude 在对话里有 `conversation_search` 和 `recent_chats` 工具，能自己搜自己的历史。所以 Feedling 不需要拉 Claude 的数据——Agent 自己会搜。用户说"帮我挑几个我们的回忆"，Claude 自己搜完、自己调用 `feedling.memory.add_moment()` 写入。这符合原则 3.4。

**不要为 v1 实现任何"从 Claude.ai 导入历史"的功能。**

### 7.3 为什么 Feedling 的 schema 不能太具体

v1 很容易写成"身份卡就是温柔/锐利/好奇/稳定四维"。但这是 Feedling 替 Agent 做了决定。

正确做法是：身份卡 schema 接受 3-5 个 `{dimension_name, value, description}` 对，每一维的名字由 Agent 自己决定。记忆花园的卡片类型也不要写死 enum（"散步"/"聊天"），让 Agent 自己写 `type` 字段。不同 Agent 展现不同风格。

### 7.4 为什么 iOS UI 这一轮先做"粗糙版"

身份卡和记忆花园的最终 UI 由设计师给出，还在做。这一轮（v1 内测版）先做一个**结构正确、视觉粗糙**的版本——radar chart 能显示数据但不做美化、卡片列表能看不做动画。**UI 定稿后会有一轮单独的 UI 升级任务**，不要提前做视觉打磨浪费时间。

---

## 8. 如何使用这份文档（给 Claude Code）

- **每次开新任务前**：读这份 `PROJECT_BRIEF.md`，再读 `ROADMAP.md` 里对应的 task
- **做任何架构决定前**：回来对照第 3 节的原则。如果某个实现会违反原则，停下来告诉用户
- **遇到 Open Decisions**（列在 ROADMAP.md 里）：停下来问用户，不要自己决定
- **不确定的时候**：宁愿问，不要猜
- **保留现有功能**：屏幕感知、灵动岛推送、Chat 长轮询这些已经跑通的东西不要破坏。新功能在旁边加，不替换

---

## 9. 术语速查

| 术语 | 含义 |
|------|------|
| Agent | 用户的 Personal Agent（OpenClaw / Hermes / Claude.ai 里的 Claude / 等等），是"大脑" |
| Feedling | iOS App + MCP server，是 Agent 的"身体" |
| MCP | Model Context Protocol，Anthropic 推的标准协议，让 Agent 调用外部工具 |
| Bootstrap | 用户第一次接入 Feedling 时，Agent 被触发执行的"aha 三连"流程 |
| Identity Card（身份卡） | Feedling 里的一张 Agent 档案页，含自我介绍 + 3-5 个维度打分 |
| Memory Garden（记忆花园） | Feedling 里的一个页面，展示 Agent 挑出来的"值得纪念的瞬间" |
| Persona | Agent 的"皮"——外观 + 语气。v1 只有 default，字段预留 |
| Dynamic Island（灵动岛） | iPhone 14 Pro 起的顶部状态显示区，Feedling 的核心"在场"媒介之一 |
| Live Activity | iOS 16.2+ 的长时间活动通知，显示在锁屏和灵动岛 |
