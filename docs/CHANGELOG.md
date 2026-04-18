# Feedling MCP — Changelog

> 这份文档记录 `PROJECT_BRIEF.md` 和 `ROADMAP.md` 的所有实质性变化。
>
> **目的**：两个月后回头看，能清楚知道某条原则、某个决定是什么时候、因为什么改的。

---

## 给 Claude Code 的说明

**每次开新对话时**，请按顺序读：
1. `PROJECT_BRIEF.md`（长期上下文）
2. `ROADMAP.md`（当前任务）
3. `CHANGELOG.md`（最近的变化——尤其是最上面 3-5 条）

**每次完成一个 task 或做出决策时**，在文档顶部追加一条记录。格式见下面。

---

## 记录格式

每条记录格式统一：

```
## YYYY-MM-DD

### [TAG] 一句话标题
- 改了什么 / 发生了什么
- 为什么改（如果是决策类）
- 影响哪些文档 / 任务
```

**Tag 用哪些**：

| Tag | 用在 |
|-----|------|
| `[BRIEF]` | PROJECT_BRIEF.md 的变化 |
| `[ROADMAP]` | ROADMAP.md 的变化 |
| `[DECISION]` | Open Decision 被拍板（记录拍了什么、为什么） |
| `[DONE]` | Task 完成标记 |
| `[BLOCKER]` | 遇到卡住的问题（不是普通 bug，是影响方向的） |
| `[PIVOT]` | 产品方向的重要调整 |
| `[UI]` | UI 设计稿更新或 UI_SPEC 变化 |
| `[FEEDBACK]` | 内测反馈驱动的改动 |

---

## 记录正文（最新的在上面）

---

## 2026-04-18

### [DONE] Phase 0 T0.1 + Phase 1 T1.1/T1.2/T1.3 + Phase 2 T2.1-T2.5 + T3.1/T3.2/T4.2

**后端 (backend/app.py)**
- 新增 identity card HTTP endpoint（init/get/nudge），5 维固定
- 新增 memory garden HTTP endpoint（add/list/get/delete）
- 新增 bootstrap endpoint（first_time 返回 instructions，already_bootstrapped 防重复）
- T3.1：删除 `should_notify`，改为 `rate_limit_ok`（纯平台层 flag）
- T3.2：push payload 通用化，ContentState 改为 title/subtitle/body/personaId/templateId/data
- T4.2：`bootstrap_events.jsonl` 日志（bootstrap_started / identity_written / memory_moment_added）

**MCP server (backend/mcp_server.py)**
- 新建 FastMCP server，14 个 tool，全部调 localhost:5001
- push tool 参数同步更新为新 ContentState 字段

**部署 (deploy/)**
- Caddyfile：mcp.feedling.app → 5002，api.feedling.app → 5001
- 3 个 systemd service（feedling-backend / feedling-mcp / feedling-chat-bridge）
- setup.sh + feedling.env.example

**iOS (testapp/)**
- T3.2：ScreenActivityAttributes.ContentState 改为通用字段
- T3.2：ScreenActivityWidget.swift 渲染 title/body/subtitle
- T2.4：AppTab 扩展为 chat/identity/garden/settings 四 tab
- T2.1：IdentityView.swift + IdentityViewModel.swift（radar chart，5 维，10s 轮询）
- T2.2：MemoryGardenView.swift + MemoryViewModel.swift（卡片列表，10s 轮询，新卡片高亮）
- T2.3：Settings 加 Connection section（API URL + pairing code 占位符）
- T2.5：bootstrap 检测（identity nil → non-nil 时自动切到 Identity tab）
- FeedlingTestApp.swift：注入 IdentityViewModel / MemoryViewModel

### [DECISION] chat_bridge 改为 opt-in，默认不启动

- chat_bridge.py 是临时 Hermes 自动回复桥，有了真 MCP Agent 后会冲突
- 迁移到 systemd 后 feedling-chat-bridge service 只 install 不 enable
- Hermes 用户手动 `systemctl enable feedling-chat-bridge`，Claude.ai / OpenClaw 用户不需要跑

### [DECISION] 身份卡维度固定 5 个

- v1 先硬编码 5 维，UI 定稿后再调整
- 影响：T1.1 数据库 schema dimensions 数组长度验证改为 exactly 5；Open Decision #1 关闭

### [DECISION] 删除 T0.2 OAuth server，不做

- Claude.ai connector UI 只需填 Name + URL，不需要 OAuth
- 删除 ROADMAP T0.2（OAuth 2.1 + Dynamic Client Registration）
- 删除 Open Decision #1（自建 vs Auth0）
- 影响：PROJECT_BRIEF Section 6.1 和 Section 7.1 去掉 OAuth 相关描述

---

## 2026-04-18

### [BRIEF][ROADMAP] 项目起点 / Project kickoff

- 建立 `PROJECT_BRIEF.md` 和 `ROADMAP.md` 两份文档
- 两周 roadmap：Phase 0（MCP server 层）→ Phase 1（身份卡 + 记忆花园后端）→ Phase 2（iOS UI 粗糙版）→ Phase 3（技术债）→ Phase 4（内测准备）
- 目标用户：人机恋群体 + 用 Claude / ChatGPT / 自跑 Agent 的技术派
- 内测渠道：300 人的人机恋群里挑 30-100 人
- 核心原则：Feedling 不替换只增补；身体 vs 大脑；Feedling 没有意见
- 关键产品决定：Claude.ai 用户的记忆花园数据来源 = Agent 自己用 `conversation_search` 搜历史，Feedling 不导入任何 Claude 数据

### [ROADMAP] 记下 4 个 Open Decisions 待定

1. OAuth server 自建还是 Auth0
2. 身份卡维度数量严格 3-5 还是完全自由
3. Persona 系统 v1 要不要对用户可见
4. UI 设计稿定稿时间

---

## 模板示例（删掉或保留都行）

以下是几条示例，展示不同情境下该怎么记：

---

## 2026-04-22（示例）

### [DONE] Phase 0 完成
- T0.1 FastMCP server 层跑通
- T0.2 OAuth 用了 Auth0 免费 tier（见下面 DECISION）
- T0.3 Caddy + Let's Encrypt 部署在 `mcp.feedling.app`
- T0.4 claude.ai 里成功添加 custom connector，推送 "hello from Claude" 到灵动岛成功
- **实际用时：2.5 天（估计 3 天，稍快）**

### [DECISION] OAuth 用 Auth0 不自建
- **选择**：Auth0 免费 tier
- **原因**：两周 scope 下自建 OAuth 2.1 + DCR 风险太高，Auth0 能节省 2 天
- **影响**：v2 可能会自建替换，届时需要迁移策略
- **影响文档**：ROADMAP Open Decisions #1 勾掉

---

## 2026-04-25（示例）

### [UI] 设计师给出身份卡/记忆花园定稿
- 新增 `docs/UI_SPEC.md`
- 身份卡确定为六边形（不是五边形），6 维
- **影响 Open Decision #2**：维度数量定为严格 6 维（不是 3-5）
- **影响 ROADMAP**：
  - 新增 Phase 2.5 "UI polish"，预计 2 天
  - Phase 1 的 identity schema 里 dimensions 数组长度约束改为 6
  - 已写入数据库的测试数据需要 migration

### [ROADMAP] 删除一个 task
- T3.5 "Mock endpoint 清理" 挪到 v2，v1 不做

---

## 2026-05-02（示例）

### [FEEDBACK] 内测第一周反馈
- 15 个用户接入成功，3 个卡在 Claude.ai connector 授权环节
- 共同痛点：onboarding guide 里没讲"为什么要 OAuth"，用户警惕
- **动作**：改 `docs/onboarding/claude_ai.md`，加一段"Feedling 拿到什么、拿不到什么"的解释
- 2 个用户反馈身份卡维度看不懂——维度名字是 Agent 写的，但没有解释文字默认不展开
  - **动作**：T2.1 改，默认展开第一维的 description

### [PIVOT] 削减 ChatGPT 用户支持
- 内测发现 ChatGPT Developer Mode 流程太复杂，3 个想接的都放弃了
- **决定**：v1 内测不再主推 ChatGPT 路径
- **影响**：`PROJECT_BRIEF.md` Section 6.3 → 改成"Claude.ai / Claude Desktop / 自跑 Agent"三类；ChatGPT 挪到"Not in scope"
- **不删除相关代码**——只是不在 onboarding 里提

---

（示例结束。实际使用中，删除上面三条示例，只保留真实发生的记录。）
