# Feedling 项目进度 Checklist

> 每次做完一件事就更新这里，下次继续时直接看这个文件。

---

## 当前目标

完整截屏上传链路已验证 ✅  
下一步：OpenClaw 心跳读取截屏内容 → 分析用户行为 → 主动推送灵动岛

---

## Phase 1：基础设施 ✅ 已完成

- [x] 写好 `skill/SKILL.md`，加载到 OpenClaw
- [x] Mock backend (`backend/app.py`) 跑在 VPS port 5001
- [x] OpenClaw 能读 Feedling API，回答"我今天手机用了什么"
- [x] iOS testapp Xcode 项目已生成（`testapp/`）
- [x] APNs 认证密钥 `.p8` 文件上传到 VPS `~/feedling/`
  - 文件名：`AuthKey_5TH55X5U7T.p8`
  - Key ID：`5TH55X5U7T`
  - Team ID：`DC9JH5DRMY`

---

## Phase 2：APNs 真实推送 ✅ 已完成

### 2a. 后端接入 APNs ✅

- [x] 在 VPS 上安装 APNs 库（`PyJWT cryptography httpx[http2]`）
- [x] 修改 `backend/app.py`：真正用 `.p8` + JWT 签名发 APNs
- [x] AWS Security Group 开放 5001 端口
- [x] 验证后端可访问：`curl http://54.209.126.4:5001/v1/screen/summary` 返回正常 ✅

### 2b. iOS App 配置 ✅

- [x] Signing 配置（Team: Honey Badger Coop. Labs Inc.）
- [x] 两个 Target 的 entitlements 加入 App Groups：`group.com.feedling.mcp`
- [x] 主 App entitlements 加入 `aps-environment: development`
- [x] Build & Run 到真机成功
- [x] App 显示 Device Token、Activity Token、Push-to-Start Token

### 2c. 端到端验证 ✅

- [x] 手机打开 App → 点"Start Live Activity" → Dynamic Island 出现 ✅
- [x] 从 VPS curl 发推送 → 手机 Dynamic Island 更新显示 "TikTok 45m" ✅
- [x] OpenClaw 自主调用 Feedling skill → 查 token → 发推送 → 灵动岛更新 ✅
- [x] 灵动岛展开样式：OpenClaw 消息全文显示（最多 5 行） ✅

---

## Phase 3：真实屏幕数据接入

### 3a. iOS 截屏上传 ✅ 已完成（2026-04-12）

- [x] 在 FeedlingTest App 内集成 Broadcast Upload Extension（`FeedlingBroadcast`）
- [x] `RPSystemBroadcastPickerView` 嵌入 ContentView（在 List 外，触摸可响应）
- [x] 系统广播弹出后选择 FeedlingTest，触发 `SampleHandler`
- [x] 每 1 秒抓一帧视频，转 JPEG（960px max edge，quality 0.6）（原 3s，已改为 1s）
- [x] Vision OCR：提取截屏中的文字和 URL（fast mode）
- [x] `WebSocketManager`：`URLSessionWebSocketTask`，自动重连，指数退避
- [x] 后端 WebSocket server 跑在 port 9998（`/ingest`）
- [x] 后端存储截屏到 `~/feedling/frames/`，按会话分目录
- [x] `GET /v1/screen/frames` 列出所有帧（含 OCR 文字）
- [x] `GET /v1/screen/frames/latest` 返回最新帧（base64 JPEG + OCR）
- [x] 验证：tcpdump 确认手机（104.28.243.105）连上 VPS:9998 ✅
- [x] 验证：frames total 从 0 增长到 11，OCR 能看到主屏 App 名称 ✅

### 3b. OpenClaw 心跳读取截屏 ✅ 已完成（2026-04-14）

- [x] 后端新增 `GET /v1/screen/analyze` 心跳端点
  - 参数：`window_sec`（默认 300）、`min_continuous_min`（默认 3）
  - 返回：`active`、`current_app`、`continuous_minutes`、`ocr_summary`、`should_notify`、`cooldown_remaining_seconds`、`reason`、`latest_ts`、`frame_count_in_window`
  - 支持短抖动容错（MAX_JITTER_FRAMES=2）
  - OCR 取最近 3 帧非空去重拼接
- [x] Push cooldown 线程安全 + 持久化
  - `_last_push_epoch` / `_last_push_mono` / `_last_push_lock`
  - 支持 `FEEDLING_PUSH_COOLDOWN_SEC` 环境变量（默认 300s）
  - `push_state.json` 持久化，重启后 cooldown 恢复
  - `_record_successful_push()` + `_cooldown_remaining_seconds()` helper
- [x] SKILL.md Heartbeat 指令更新：Step 0 long poll + Step 1-3 屏幕检查
- [x] 截帧间隔从 3s 改为 1s（`captureIntervalMsDefault=1000`）
- [x] OpenClaw SKILL.md 已更新，端到端验证待 OpenClaw 下次加载

### 3c. 替换 mock 数据 ✅ 已完成（2026-04-15）

- [x] `/v1/screen/ios` 从真实帧元数据聚合替换 mock 数据
  - `window_sec` 可配置（默认 24h）
  - 输出包含 `data_source`, `frame_count`, `unlock_count`，可区分 real vs fallback
  - `/v1/screen/summary` 已切到 iOS 实时聚合结果（Mac 仍为 mock）

### 3d. Mac 屏幕监控（待完成）

- [ ] Mac 屏幕监控数据 → 真实上传到后端
- [ ] 与 iOS 数据合并到 `/v1/screen/summary`

---

## Phase 4：Chat 窗口 + OpenClaw 双向对话 ✅ 已完成（2026-04-15）

### 4a. 后端 Chat 端点 ✅

- [x] 新增 `GET /v1/chat/history?limit&since` — 获取聊天记录
- [x] 新增 `POST /v1/chat/message` — 用户发消息
- [x] 新增 `POST /v1/chat/response` — OpenClaw 回复（可选触发 Live Activity push）
- [x] 新增 `GET /v1/chat/poll?since&timeout` — Long poll，实时推送到 OpenClaw
  - 用户发消息时立即唤醒所有等待中的 poll 请求
  - timeout 内无消息返回 `timed_out: true`，OpenClaw 顺势做屏幕检查
- [x] Live Activity push 自动镜像到 Chat（`source: "live_activity"`）
- [x] Live Activity 去重抑制：同文案短时间重复发送会返回 `status: suppressed`（防刷屏）
- [x] 聊天记录持久化到 `chat.json`，最多保留 500 条

### 4b. iOS Chat UI ✅

- [x] `ChatMessage.swift` — 数据模型（role / content / ts / source）
- [x] `ChatViewModel.swift` — 2s 轮询 + 乐观插入 + 60s loading 超时
- [x] `ChatView.swift` — 深色聊天界面，OpenClaw 气泡（深灰）+ 用户气泡（青色）
  - Dynamic Island 推送消息带 `· Dynamic Island` 标记
  - 打字动画（TypingIndicator）
  - 键盘可通过下滑或点击背景收起
- [x] `ContentView.swift` — TabView 根视图（Chat + Settings）
- [x] `FeedlingTestApp.swift` — 点击 Dynamic Island 直接跳到 Chat Tab
- [x] `FeedlingAPI.swift` — 统一 baseURL 配置（支持环境变量覆盖）

### 4c. Bug 修复 ✅

- [x] 消息重复发送 — fetchNewMessages 只处理 `role: openclaw`，过滤服务器回显
- [x] Loading 不停转 — 60s waitingTimeoutTask 自动重置
- [x] 键盘锁屏 — scrollDismissesKeyboard + tap-to-dismiss

### 4d. SKILL.md 更新 ✅

- [x] 新增 Long poll 主循环（替换原 Step 0）
- [x] 新增 `GET /v1/chat/poll` API 文档
- [x] 启动时从 history 获取 last_ts，避免重复处理旧消息

---

## 环境信息（备忘）

| 项目 | 值 |
|------|----|
| VPS 公网 IP | `54.209.126.4` |
| VPS 用户名 | `openclaw` |
| VPS 后端路径 | `~/feedling/` |
| 后端 HTTP 端口 | `5001` |
| 后端 WebSocket 端口 | `9998` |
| SSH 端口 | `443`（port 22 有问题，用 443 绕过） |
| APNs Key ID | `5TH55X5U7T` |
| APNs .p8 路径（VPS） | `~/feedling/AuthKey_5TH55X5U7T.p8` |
| Apple Team ID | `DC9JH5DRMY` |
| App Bundle ID | `com.feedling.mcp` |
| Broadcast Extension Bundle ID | `com.feedling.mcp.broadcast` |
| Widget Bundle ID | `com.feedling.mcp.widget` |
| App Group | `group.com.feedling.mcp` |
| 截屏存储路径（VPS） | `~/feedling/frames/<session_id>/` |

---

## 最近操作日志

### 2026-04-12（Phase 3a）

- 新增 `FeedlingBroadcast` Broadcast Upload Extension
  - `SampleHandler.swift`：RPBroadcastSampleHandler，每 3 秒抓帧
  - `SampleHandler+WebSocketQueue.swift`：Vision OCR + WebSocket 发帧
  - `WebSocketManager.swift`：URLSessionWebSocketTask，无三方依赖，自动重连
  - `SharedConfig.swift`：App Group 共享配置
- `project.yml` 加入 FeedlingBroadcast / FeedlingBroadcastSetupUI 两个 target，作为主 App 依赖
- `project.yml` entitlements inline properties（防止 xcodegen 清空 App Groups）
- 后端加 WebSocket server（port 9998，`/ingest` 路由）
- 后端加 `_save_frame()` 存储 base64 JPEG
- 后端加 `/v1/screen/frames`, `/v1/screen/frames/latest`, `/v1/screen/frames/<filename>` 端点
- ContentView 加 `RPSystemBroadcastPickerView`（放在 List 外才可点击）
- AWS Security Group 开放 9998 端口
- scp 上传后端用 `-P 443`（SSH port 443 绕过）
- **端到端验证成功：手机录屏 → WebSocket → VPS 存储 → OCR 可见** ✅

### 2026-04-12（Phase 2）

- 排查 SSH 连接问题（用户名应为 `openclaw` 不是 `ubuntu`）
- 把 Mac 公钥加到 VPS `~/.ssh/authorized_keys`
- 成功上传 `AuthKey_5TH55X5U7T.p8` 到 VPS `~/feedling/`
- 后端接入真实 APNs（PyJWT + httpx[http2]）
- AWS Security Group 开放 5001 端口
- 修复 entitlements（App Groups + aps-environment）
- 修复 iOS deployment target 16.1 → 16.2（Live Activity 要求 16.2+）
- 修复 APNs payload 里 `updatedAt` 格式（ISO字符串→Unix时间戳）
- **端到端验证成功：VPS → APNs → 灵动岛显示 TikTok 45m** ✅
- 修复 token 类型不一致（live_activity vs live-activity，两者都接受）
- 加入 iOS ATS 例外（NSAllowsArbitraryLoads，允许 HTTP 连接 VPS）
- **OpenClaw 自主完成全链路：查 token → Feedling API → APNs → 灵动岛** ✅
- 灵动岛展开：OpenClaw 消息最多 5 行，compact trailing 截断到 18 字符 ✅
