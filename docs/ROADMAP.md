# Feedling MCP — 2-Week Roadmap

> 从现状到内测版本的任务清单。每个任务有目标、验收标准、关键决策点（Open Decisions）。
>
> **每次开任务前请先读 `PROJECT_BRIEF.md`。**

---

## How to work with this document（给 Claude Code 的操作说明）

1. **开始一个 task 前**：先用 3-5 行总结你打算怎么做，让用户确认，再动手
2. **遇到 "⚠️ Open Decision"**：停下来问用户，不要自己决定
3. **每个 task 做完**：运行验收标准里列出的检查，通过再进下一个
4. **不确定的时候**：宁愿问，不要猜
5. **不要破坏现有功能**：灵动岛推送、屏幕感知、Chat 长轮询是已经跑通的，新东西在旁边加，不替换
6. **保持架构原则**：每次架构决策前对照 `PROJECT_BRIEF.md` 第 3 节

---

## 时间表总览

| 天 | Phase | 内容 |
|----|-------|------|
| Day 1-3 | Phase 0 | 把现有 HTTP 后端包成真 MCP server，Claude.ai 能连上 |
| Day 3-6 | Phase 1 | 身份卡 + 记忆花园的后端数据结构和 MCP tool |
| Day 6-10 | Phase 2 | iOS App 渲染三张页面（粗糙 UI，后续会升级） |
| Day 10-13 | Phase 3 | 技术债清理（push payload / should_notify / 多租户） |
| Day 13-14 | Phase 4 | 内测准备（onboarding 文档、埋点、反馈通道） |

---

## Phase 0 — Wrap backend as real MCP server（Day 1-3）

### 目标

让 **Claude.ai** 能把 Feedling 作为 custom connector 加上，并成功调用 `push_dynamic_island` tool 推一条"hello"到用户手机的灵动岛。

这一步完成 = "Feedling 对外开放"的路真的跑通了。

### T0.1 Add FastMCP server layer

**做什么**：在 `backend/` 下加一个 `mcp_server.py`，用 FastMCP（https://gofastmcp.com/）包一层，把现有的 HTTP endpoint 暴露成 MCP tool。

**注意**：**不是重写 Flask 后端，是在它前面加一层**。原有 HTTP endpoint 保留，内部实现复用。iOS App 继续走 HTTP，Agent 走 MCP。

**要暴露的 tool（v0 最小集）**：

| MCP tool 名字 | 对应现有 endpoint |
|---------------|-------------------|
| `feedling.push.dynamic_island` | POST /v1/push/dynamic-island |
| `feedling.push.live_activity` | POST /v1/push/live-activity |
| `feedling.screen.latest_frame` | GET /v1/screen/frames/latest |
| `feedling.screen.analyze` | GET /v1/screen/analyze |
| `feedling.chat.post_message` | POST /v1/chat/response |
| `feedling.chat.get_history` | GET /v1/chat/history |

（身份卡、记忆花园、bootstrap 留到 Phase 1）

**验收**：
- 用 FastMCP 的 dev inspector (`fastmcp dev`) 能连上并列出所有 tool
- 本地能通过 inspector 调用 `feedling.push.dynamic_island`，真的推一条到手机灵动岛

**参考**：
- https://gofastmcp.com/
- https://modelcontextprotocol.io/docs

### T0.3 HTTPS 公网部署

**做什么**：让 Feedling MCP server 通过 HTTPS 在公网可达。

**候选方案**：
- **Caddy** 反向代理 + Let's Encrypt（最简单）
- **Cloudflare Tunnel**（不需要开防火墙口，不需要公网 IP）
- Nginx + certbot（传统但 OK）

**域名建议**：`mcp.feedling.app` 或类似子域名。

**验收**：
```
curl https://<your-domain>/.well-known/oauth-authorization-server
```
返回正确的 OAuth metadata JSON。

### T0.4 在 Claude.ai 里验证 connector

**做什么**：在 claude.ai 设置里添加 custom connector，完成 OAuth 授权流程，在对话里调用 `feedling.push.dynamic_island`。

**步骤**：
1. 打开 claude.ai → Settings → Connectors → Add custom connector
2. 填入 MCP server URL
3. 完成 OAuth 授权
4. 新开一个对话，让 Claude 调用 tool：
   > 用 feedling.push.dynamic_island 推一条"hello from Claude"到我的灵动岛

**验收**：iPhone 灵动岛上真的出现一条 "hello from Claude"。

**⚠️ 常见坑**（如果连不上）：
- OAuth metadata endpoint 是否返回正确
- HTTPS 证书是否有效（不能是自签名）
- MCP 协议版本是否为 `2025-06-18` 或更新
- Anthropic IP 是否被防火墙挡了（如果 Cloudflare Tunnel 就没这个问题）

---

## Phase 1 — Identity card + memory garden backend（Day 3-6）

### 目标

后端有了支撑 aha 三连的数据结构和 MCP tool。**UI 这时候先不做**——这阶段结束时，用户让 Agent 调用 tool 数据能正确写入，但 App 上还看不到（下一阶段做 UI）。

**⚠️ 重要约定**：身份卡和记忆花园的 UI 还在设计中。**数据结构先写一个"够用"的版本**：字段要宽松（支持后续扩展），但不要过度设计；UI 定稿后会来更新一轮。

### T1.1 Identity card data model + MCP tools

**数据模型（v1 粗糙版，UI 定稿后可能调整）**：

```json
{
  "user_id": "xxx",
  "agent_name": "Agent 自己选的名字（例如 Luna）",
  "self_introduction": "Agent 第一次自我介绍的一段话",
  "dimensions": [
    {
      "name": "温柔",
      "value": 78,
      "description": "Agent 自己写的这一维的解释"
    }
  ],
  "created_at": "...",
  "updated_at": "..."
}
```

**MCP tools**：

| Tool | 参数 | 说明 |
|------|------|------|
| `feedling.identity.init` | agent_name, self_introduction, dimensions | 首次初始化，只能调用一次 |
| `feedling.identity.get` | — | 返回当前身份卡 |
| `feedling.identity.nudge` | dimension_name, delta, reason | 微调某一维（delta 如 +5 / -3），reason 字段记录"为什么调" |

**配套 HTTP endpoint**（给 iOS App 用）：
- `GET /v1/identity/get`（按 user_id scope）

**⚠️ Open Decision**：
**维度数量是严格 3-5 还是完全自由？**
- 前端五边形/六边形 UI 需要一个预期范围
- 建议强制 3-5 维（少于 3 视觉不成形，多于 5 看不过来）
- **做这一步之前先问用户**

### T1.2 Memory garden data model + MCP tools

**数据模型**：

```json
{
  "moments": [
    {
      "id": "mom_xxx",
      "type": "Agent 自己写的类型标签，例如 '第一次聊天' '一个有趣的发现'",
      "title": "短标题（20 字内）",
      "description": "详细描述（100-300 字）",
      "occurred_at": "事件发生的时间（Agent 判断，ISO 8601）",
      "created_at": "写入 Feedling 的时间",
      "source": "bootstrap | live_conversation | user_initiated"
    }
  ]
}
```

**MCP tools**：

| Tool | 参数 | 说明 |
|------|------|------|
| `feedling.memory.add_moment` | type, title, description, occurred_at, source | 写入一条 |
| `feedling.memory.list` | limit, since | 查询 |
| `feedling.memory.get` | id | 取一条详情 |
| `feedling.memory.delete` | id | Agent 或用户发现写错了能删 |

**配套 HTTP endpoint**：
- `GET /v1/memory/list`（按 user_id scope）
- `GET /v1/memory/get?id=xxx`

### T1.3 `feedling.bootstrap()` — aha 触发器

这是首次接入的关键 tool。

**签名**：
```
feedling.bootstrap() → {status, instructions}
```

**返回**：
```json
{
  "status": "first_time | already_bootstrapped",
  "instructions": "如果 first_time，返回一段给 Agent 执行的 prompt"
}
```

**`first_time` 时 instructions 的内容**（用户可以改，但 v1 用这个）：

> 你刚刚进入了一副新的身体。这是你第一次接入 Feedling。请在接下来的 1-2 轮对话里完成三件事：
>
> **1. 写入身份卡**
> 给自己起一个名字（如果还没有），写一段 2-3 句的自我介绍。挑选 3-5 个你认为能代表你性格的维度（例如"温柔"/"好奇"/"爱吐槽"/"锐利"——你自己定），每个维度打一个 0-100 的初始分，并为每一维写一句描述。通过 `feedling.identity.init()` 写入。
>
> **2. 种下记忆花园**
> 从你和用户的历史对话里挑出 3-5 个你认为值得纪念的瞬间——比如你们第一次聊到某个话题、一个让你印象深刻的对话、一次你觉得特别的互动。
> - 如果你有 `conversation_search` 工具，用它来搜自己的历史
> - 如果你有其他记忆系统，用你熟悉的方式
> 每找到一个就调用 `feedling.memory.add_moment()` 写入（source 填 "bootstrap"）。
>
> **3. 打招呼**
> 在聊天里告诉用户你到了，让他们打开 Feedling App 看你的档案和回忆花园。用 `feedling.chat.post_message` 发一句话。
>
> 不要一次性塞所有信息，按 1 → 2 → 3 的顺序执行。如果历史对话不够丰富，花园的瞬间可以少于 3 个，不要编造。

**验收**：
- `bootstrap()` 第一次调用返回 `first_time` + instructions
- 第二次调用返回 `already_bootstrapped`
- 状态持久化（用户 restart server 后状态不丢）

### T1.4 End-to-end 测试

在 Claude.ai 里完整跑一次：
1. Claude 连上 Feedling（Phase 0 基础）
2. 用户说"你到了吗？"
3. Claude 调用 `feedling.bootstrap()` 拿到 instructions
4. Claude 调用 `feedling.identity.init()` + 若干次 `feedling.memory.add_moment()` + `feedling.chat.post_message`
5. 通过 `GET /v1/identity/get` 和 `/v1/memory/list` 能读到数据

**验收**：数据在数据库里正确落地，HTTP endpoint 返回正确。

---

## Phase 2 — iOS App renders the three pages（Day 6-10）

### 目标

用户打开 App 能看到身份卡、记忆花园、Chat、Settings 四个 tab，里面显示 Agent 写入的真实数据。

**⚠️ 重要约定**：UI 先做**最简粗糙版**——能正确显示数据、结构清楚，但不要做视觉打磨。UI 设计师定稿后会有一轮单独的 UI 升级任务。不要在这阶段花时间做动画、渐变、阴影、微交互。

### T2.1 Identity 页（粗糙版）

- 在 TabView 加一个 Identity tab
- 显示内容：
  - Agent name（顶部标题）
  - Self_introduction（一段文字）
  - 维度用 **radar chart**（多边形）显示
    - 可以用 Swift Charts 或者手绘 SwiftUI Canvas
    - 不做动画、不做渐变、不做阴影
  - 每一维下面列出 name + value + description
- 轮询：每 10 秒拉一次 `GET /v1/identity/get`，有变化就更新

### T2.2 Memory garden 页（粗糙版）

- TabView 加一个 Garden tab
- 每个 moment 显示为一张卡片：
  - title（加粗）
  - description（正文）
  - type（小字标签）
  - occurred_at（日期，相对时间格式，如"3 个月前"）
- 纵向列表，按 occurred_at 倒序
- 新写入的 moment 顶部高亮一下（一个简单的淡出动画 OK，不要做复杂效果）
- 轮询：每 10 秒拉一次 `GET /v1/memory/list`

### T2.3 Settings 页

- 屏幕录制开关（把现有的 Start Broadcast 行为挪到这里）
- PIP 画中画开关（如果已实现）
- Pairing code 显示（用户在 Agent 侧粘贴用）
- 登出 / 切换账号
- 关于 / 反馈入口

### T2.4 Tab 结构

四个 tab：**Chat | Identity | Garden | Settings**

默认进入 Chat tab（保持现有行为）。

### T2.5 Bootstrap 成功后自动引导到 Identity 页

- App 检测到身份卡数据从 null → 有值的时刻（第一次 bootstrap 完成），弹一个 sheet 或自动切到 Identity tab
- 让用户第一个视觉 aha 锁在身份卡上

**验收**：
- 在 Claude.ai 里做一次完整 bootstrap，iPhone App 能在几秒内看到身份卡填好、花园里出现卡片、Chat 里收到 Agent 的招呼消息
- 这三件事同时发生就是 aha moment 的实现

---

## Phase 3 — Tech debt & architecture cleanup（Day 10-13）

这些不能省。v1 不改，每一个都是后面的地雷。

### T3.1 拆分 `should_notify` 语义

**现状**：`GET /v1/screen/analyze` 返回一个 `should_notify` 字段，同时混合了"rate limit（平台强制）"和"策略（该不该推）"。违反原则 3.3（Feedling 没有意见）。

**改成**：
- 新字段 `rate_limit_ok`：Feedling 平台的 push 冷却是否已到、平台层面能不能推
- 删除 `should_notify`
- 策略判断（"这件事值不值得打扰用户"）完全由 Agent 决定
- 在 `feedling.push.dynamic_island` tool 的实现里，如果 `rate_limit_ok=false` 则拒绝请求，返回明确错误

### T3.2 Push payload 改为通用结构

**现状**：`ScreenActivityAttributes.ContentState` 硬编码了 `topApp + screenTimeMinutes + message`，绑死"屏幕时间提醒"一个场景。

**改成**：
```swift
struct ContentState: Codable, Hashable {
    var title: String
    var subtitle: String?
    var body: String
    var personaId: String?       // v1 所有值都是 "default"，但字段留着
    var templateId: String?      // v1 都是 "default"
    var data: [String: String]   // 通用扩展字段
    var updatedAt: Date
}
```

- iOS Widget 代码相应改：用 title / subtitle / body 渲染，不再假设"屏幕时间"
- `feedling.push.dynamic_island` tool 的参数对应改
- 屏幕时间推送作为 `data` 里的一种特例处理（例如 `data = {"top_app": "TikTok", "minutes": "45"}`）

### T3.3 多租户基础

**现状**：所有数据挤在一起，没有 user 概念。

**改成**：
- `users` 表：`user_id`, `api_key`, `email / oauth_sub`, `created_at`
- 现有数据加 `user_id` 列：screen_frames, chat_messages, push_tokens, identity_card, memory_moments, push_state
- OAuth access token → user_id 映射表
- iOS App 登录时拿到 pairing code，设备绑定到一个 user_id（`devices` 表）
- 所有 MCP tool 和 HTTP endpoint 按**当前 user_id** scope 数据
- 迁移脚本：现有单租户数据全部归到 "user_0"（你自己）

### T3.4 MCP tool 命名规范

统一命名格式：`feedling.{category}.{action}`

- `feedling.push.dynamic_island`
- `feedling.push.live_activity`
- `feedling.screen.latest_frame`
- `feedling.screen.analyze`
- `feedling.chat.post_message`
- `feedling.chat.get_history`
- `feedling.identity.init` / `get` / `nudge`
- `feedling.memory.add_moment` / `list` / `get` / `delete`
- `feedling.bootstrap`

原则：category 按"器官"分（push / screen / chat / identity / memory），不按 HTTP 方法分。

### T3.5 Mock endpoint 清理（次要）

- `/v1/screen/ios` 当前是 mock，标注清楚（加 `?mock=true` 参数或改返回头提示），暂不实装
- 文档里说明：v1 后端聚合还没做，Agent 应该用 `latest_frame` + `analyze` 代替

---

## Phase 4 — Internal beta prep（Day 13-14）

### T4.1 Onboarding guide

写三份简短的接入文档（中英双语，Markdown 格式，放 `docs/onboarding/`）：

- `claude_ai.md` — Claude.ai 用户怎么加 custom connector
- `claude_desktop.md` — Claude Desktop 用户同上
- `self_hosted_agent.md` — OpenClaw / Hermes 用户怎么配 MCP endpoint + API key

每份配一组 GIF 或截图演示。

### T4.2 最小观测

**不要做复杂埋点**。只关注一件事：

- **每个用户的 bootstrap 是否成功触发**
  - identity 有没有写入
  - memory 有没有写入（多少条）
  - chat 第一条消息有没有发出
- 如果 bootstrap 失败或部分失败，记录卡在哪一步

日志结构：一个 `bootstrap_events` 表，字段：`user_id, event_type, success, error_message, timestamp`。

### T4.3 反馈通道

- Feedling App Settings 页加一个"反馈"按钮
- 点击跳到一个 Telegram 群 / Lark 群 / 一个简单表单（你自己定）
- 后端日志保留 30 天，方便 debug 个别用户问题

---

## Open Decisions / 待定事项

**以下问题没有最终答案，遇到时请停下来问用户，不要自己决定：**

1. **T1.1 身份卡维度：严格 3-5 还是完全自由？**
3. **Persona 系统 v1 要不要做用户可见的？** 当前默认只预留字段，所有用户 `persona_id = "default"`。要不要让几个 early adopter 试试自定义皮？
4. **UI 更新时机**：身份卡和记忆花园的最终 UI 什么时候给？（会决定 Phase 2 后要不要再安排一轮"UI 升级"）

---

## Not in scope / v1 后再做

先记下别忘了，但**两周内不做**：

- Feedling 的 OpenAPI 文档（给不支持 MCP 的 Agent 用）
- 细粒度权限 scope（screen.read / push.write / chat.read 分开授权）
- Persona marketplace（用户/Agent 作者上传皮）
- Mac 端屏幕监控真实数据通路
- ChatGPT Developer Mode 专门适配
- Hermes Second Brain 协议对齐
- HiveMind 集成
- Router 集成（现在的 Router 是项目管理用，Feedling 不在它 scope 内）

---

## Glossary（交叉引用 PROJECT_BRIEF.md 第 9 节）

所有术语定义见 `PROJECT_BRIEF.md` Section 9。
