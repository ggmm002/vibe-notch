# Vibe Notch 兼容 Codex CLI —— MVP 方案

## 目标与硬约束

让 Vibe Notch 在监控 Claude Code 之外，同时监控 OpenAI Codex CLI 会话，体验对齐 Claude：实时状态、刘海内审批、聊天记录。

硬约束只有一条：**不能影响现有 Claude 用户**。落实成三个不可破坏的规则：

1. Codex 支持是**纯增量、可选开关**，默认关闭。用户不开启时，Codex 相关代码一行不跑。
2. **永不写入 `~/.claude`**，永不修改 `claude-island-state.py`、`settings.json`、socket 路径、bundle id。
3. 共享文件（`SessionStore`、`HookSocketServer`、`SessionState`）只做 additive 改动，Claude 分支等价于当前代码。

可量化的验收：开关关闭时构建出的 App，对任意不开启 Codex 的用户行为与当前版本逐字节等价。

## MVP 范围

做什么、不做什么，以及为什么这么切。

| 能力 | MVP | 实现方式 |
|---|---|---|
| Codex 会话实时状态（处理中/待输入/待审批/空闲） | 做 | 纯 hook 事件驱动 |
| 刘海内审批工具（allow/deny） | 做 | Codex `PermissionRequest` 同步 hook |
| 聊天记录 | 做（降级版） | 用 hook 事件重建，不解析 rollout JSONL |
| rollout JSONL 全保真解析 | **不做**，Phase 2 | 见下方取舍 |
| Codex subagent 展示 | 不做 | Codex 无 Task 工具，`SubagentState` 空转 |
| `codex exec --ephemeral` 会话 | 不做 | 无 rollout 文件，hook 实时状态仍可用 |

### 为什么 MVP 不做 rollout JSONL 解析

Codex 的 rollout 文件（`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`）是 `RolloutLine` 包 `RolloutItem` 的格式，与 Claude 的 `type:user/assistant + content blocks` 完全不同。问题在于工具调用/结果的字段级 schema 没有公开文档，要去反推 `codex-rs/protocol/src/protocol.rs`。这是整个项目唯一的高风险、高耗时项（5–9 天），且估时方差大。

替代方案：**用 hook 事件重建聊天记录**。Codex 的 hook payload 已经携带：

- `UserPromptSubmit` → `prompt`（用户输入）
- `PreToolUse` / `PostToolUse` → `tool_name`、`tool_input`、`tool_response`（工具调用与结果）
- `Stop` → `last_assistant_message`（该轮最终助手回复）

这覆盖了一份可用 transcript 的约 80%。缺失的是助手中间流式文本和 reasoning 块——MVP 阶段可接受的降级。Phase 2 再用 rollout parser 透明替换，对上层 `ChatHistoryItem` 模型无破坏。

被否决的另一选项是 MVP 直接上 rollout parser：它把交付周期从 2.5 周拉到 4 周，且把最大不确定性压在关键路径上。MVP 不该背这个风险。

## 架构：隔离设计

核心是给每个 session 打上 agent 类型标签，在边界处分流，中间的状态机和 UI 全部复用。

```
  Claude Code hooks                 Codex CLI hooks
        │                                 │
  claude-island-state.py            codex-hook.py        ← 新增，独立脚本
  (不改一个字)                       (规范化 + 决策翻译)
        │                                 │
        └────────────┬────────────────────┘
                     ▼
         /tmp/claude-island.sock          ← 同一个 socket，事件带 agent 标签
                     │
              HookSocketServer            ← 仅 HookEvent 加 agent 字段
                     │
                 SessionStore             ← 按 agentType 分流 parser
                     │
            SessionState (+agentType)     ← additive 字段
                     │
              共享 UI / 审批流             ← 不改
```

### 新增文件（全部独立，不触碰 Claude 代码路径）

- `ClaudeIsland/Models/AgentType.swift` —— `enum AgentType { case claude, codex }`
- `ClaudeIsland/Core/CodexPaths.swift` —— `~/.codex` 解析，对应 `ClaudePaths`，支持 `CODEX_HOME`
- `ClaudeIsland/Services/Hooks/CodexHookInstaller.swift` —— 写 `~/.codex/hooks.json`
- `ClaudeIsland/Resources/codex-hook.py` —— 打包进 bundle 的 Codex hook 脚本
- `ClaudeIsland/Services/Session/CodexHookHistoryBuilder.swift` —— 从 hook 事件重建聊天记录

### 共享文件的改动（全部 additive）

| 文件 | 改动 | 为什么安全 |
|---|---|---|
| `HookEvent`（`HookSocketServer.swift`） | 加 `let agent: String?`，CodingKey `agent`；计算属性 `agentType` | Optional 字段缺失时解码为 nil；Claude 脚本不发该字段 → nil → 默认 `.claude` |
| `SessionState.swift` | 加 `var agentType: AgentType = .claude` | init 给默认值，现有调用方与读取点行为不变 |
| `HookSocketServer.swift` | socket 共用，不分流；`toolUseIdCache` 直接复用 | Codex `PermissionRequest` 同样不带 `tool_use_id`，现有 FIFO 缓存机制正好适用 |
| `SessionStore.swift` | `process()` 按 `agentType` 路由历史来源 | Claude 分支 = 现有代码；新增 default 兜底到 `.claude` |
| `AppDelegate.swift` | 加一行 flag-gated 的 `CodexHookInstaller.installIfNeeded()` | flag 关闭时为 no-op |
| `Settings.swift` | 加 `codexMonitoringEnabled`（默认 `false`）、`codexDirectoryName` | 新 key，不影响现有设置 |

`HookEvent` 改动示例（保持向后兼容解码）：

```swift
struct HookEvent: Codable, Sendable {
    // ... 现有字段不变 ...
    let agent: String?   // Claude 脚本不发 → nil

    var agentType: AgentType {
        AgentType(rawValue: agent ?? "claude") ?? .claude
    }
}
```

## Hook 接入

Codex CLI 的 hook 系统与 Claude Code 高度同构，事件经 stdin 收 JSON、stdout 回 JSON。`codex-hook.py` 的职责：把 Codex 的 hook payload 规范化成现有 socket 协议的 `HookEvent`，并把 App 回写的决策翻译回 Codex 格式。

### 事件映射

Codex 的 stdin 公共字段：`session_id`、`transcript_path`、`cwd`、`hook_event_name`、`model`、`permission_mode`。

| Codex 事件 | App 内部 status | 备注 |
|---|---|---|
| `SessionStart` | `starting` | 带 `source`（startup/resume/clear） |
| `UserPromptSubmit` | `processing` | 携带 `prompt`，喂给历史重建 |
| `PreToolUse` | `running_tool` | 缓存 `tool_use_id` 供 `PermissionRequest` 关联 |
| `PermissionRequest` | `waiting_for_approval` | **同步**，socket 保持打开等回写 |
| `PostToolUse` | `processing` | 携带 `tool_response`，标记工具完成 |
| `Stop` | `waiting_for_input` | 携带 `last_assistant_message` |

Codex 没有 `PreCompact`、`SessionEnd`、`Notification`。会话结束靠 `Stop` 后转 idle，再由现有 stale-session 回收机制兜底。

### 决策回写翻译

Claude 的回写格式是 `{"decision": "allow"|"deny", "reason": ...}`。Codex 的 `PermissionRequest` 要求不同的 stdout：

```python
# App 经 socket 回写 {"decision": "allow"} 后，codex-hook.py 翻译为：
# allow:
{"hookSpecificOutput": {"decision": {"behavior": "allow"}}}
# deny:
{"hookSpecificOutput": {"decision": {"behavior": "deny", "message": "<reason>"}}}
```

翻译逻辑只放在 `codex-hook.py` 里，Swift 侧的 `HookResponse` 保持 agent 无关。`PreToolUse` 不在 MVP 用作 guardrail——只用 `PermissionRequest` 做审批，与 Claude 路径对齐。

## 安装器：写 hooks.json

`CodexHookInstaller` 在 `~/.codex/hooks.json` 注册我们的 hook，命令指向打包脚本：

```json
{
  "hooks": {
    "PreToolUse":        [{"matcher": "*", "hooks": [{"type": "command", "command": "<python> <codex-hook.py>"}]}],
    "PermissionRequest": [{"matcher": "*", "hooks": [{"type": "command", "command": "<python> <codex-hook.py>"}]}],
    "PostToolUse":       [{"matcher": "*", "hooks": [{"type": "command", "command": "<python> <codex-hook.py>"}]}],
    "UserPromptSubmit":  [{"hooks": [{"type": "command", "command": "<python> <codex-hook.py>"}]}],
    "Stop":              [{"hooks": [{"type": "command", "command": "<python> <codex-hook.py>"}]}],
    "SessionStart":      [{"hooks": [{"type": "command", "command": "<python> <codex-hook.py>"}]}]
  }
}
```

安装器是 merge-aware：读现有 `hooks.json` → 剔除我们自己的旧条目（按命令路径含 `codex-hook.py` 识别）→ 合入新条目 → 写回。复用 `HookInstaller` 已验证过的 dedup 套路。

**为什么不选编辑 `config.toml`**：Codex 也支持在 `config.toml` 内联 `[hooks]` 表，但 `config.toml` 是用户的核心配置文件，编辑它要保留注释和格式，写坏的影响面大。`hooks.json` 是一个我们独占管理的独立文件，新建/合并它不会波及用户其他配置。Claude 端被迫编辑 `settings.json` 是因为没有别的入口；Codex 给了独立文件这条路，就用它。

**版本门控**：Codex hooks 是较新功能。`CodexHookInstaller` 先跑 `codex --version`，版本过低则不安装，并在设置页提示「当前 Codex 版本不支持监控」。版本探测失败时一律不安装——宁可没有功能，不可写坏配置。

## 对 Claude 零影响的保障

逐项核对，每条都要能在 review 时直接验证：

- **脚本隔离**：`claude-island-state.py` 不改；Codex 用独立的 `codex-hook.py`。Claude 用户 `settings.json` 里的命令路径永不被重写。
- **路径隔离**：`CodexHookInstaller` 只写 `~/.codex/`。`ClaudePaths`、`HookInstaller`、`ConversationParser` 不改一行。
- **开关兜底**：`codexMonitoringEnabled` 默认 `false`。关闭时 `CodexHookInstaller.installIfNeeded()` 是 no-op，不探测 `codex` 二进制、不写任何文件。这是「shipped build 对未开启用户零行为变化」的硬保障。
- **解码兼容**：`HookEvent` 新增 `agent` 为 Optional，旧 Claude 脚本不发该字段时解码为 nil，回退 `.claude`。
- **分流兜底**：`SessionStore` 按 `agentType` 路由，default 分支走 Claude 逻辑。Codex 解析器抛错不污染 Claude session 状态。
- **回滚**：用户关掉开关即彻底停用 Codex 路径，无需卸载或回滚配置。

## 工作量与排期

单人估时，单位为工作日。

| 任务 | 估时 | 难度 |
|---|---|---|
| `AgentType` 枚举 + `SessionState`/`HookEvent` additive 字段 | 1 | 低 |
| `codex-hook.py`：事件规范化 + 决策翻译 | 1.5 | 低 |
| `CodexPaths`（`~/.codex`、`CODEX_HOME`） | 0.5 | 低 |
| `CodexHookInstaller`：写 hooks.json + 版本门控 | 2.5 | 中 |
| `SessionStore` agentType 分流 | 1.5 | 中 |
| `CodexHookHistoryBuilder`：hook 事件重建聊天记录 | 3 | 中 |
| 工具名映射（`apply_patch`/`Bash`/MCP）+ UI 文案 agent 化 | 1.5 | 中低 |
| 设置 UI：Codex 开关 + 目录选择 + 会话行 agent 标识 | 2 | 低 |
| 联调 + 手动验证 | 2 | —— |

**合计约 15.5 天 ≈ 3 周。** Phase 2（rollout JSONL 全保真解析）另算 5–9 天。

## 已知限制与风险

- **rollout schema 未公开**：Phase 2 的 `CodexConversationParser` 要反推 `codex-rs` 源码，估时方差最大。MVP 用 hook 重建规避了这条关键路径风险。
- **会话结束检测模糊**：Codex 无 `SessionEnd` 事件，会话结束只能靠 `Stop` 后超时回收，可能短暂显示已结束的会话。
- **聊天记录降级**：MVP 的 hook 重建缺助手中间流式文本和 reasoning 块。Phase 2 修复。
- **老版 Codex 无 hooks**：版本过低的用户无法监控 Codex，设置页明确提示，不静默失败。
- **`PermissionRequest` 不带 `tool_use_id`**：与老版 Claude 同样的问题，复用 `HookSocketServer` 现有的 `sessionId:toolName:input` FIFO 缓存解决。
- **多 hook 并发**：Codex 对同一事件的多个匹配 hook 并发执行、「任一 deny 生效」。单一 Vibe Notch hook 不受影响，但要注意我们的 hook 不能假设自己是唯一决策方。

## 验证清单

无测试 target，验证靠构建 + 手动运行：

1. `xcodebuild -scheme ClaudeIsland -configuration Debug build` 通过。
2. **开关关闭**运行：确认 `~/.codex/hooks.json` 未被创建，Claude 会话监控与审批行为与当前版本一致。
3. **开关开启**运行：跑一个 Codex CLI 会话，确认刘海出现 Codex session、状态随处理/待输入切换。
4. 在 Codex 会话触发一次工具审批，确认刘海弹出 allow/deny，点击后 Codex 终端继续执行。
5. 确认 Codex 会话的聊天记录视图显示用户输入、工具调用与最终回复。
6. 同时跑 Claude 与 Codex 会话，确认两者状态互不串扰。
