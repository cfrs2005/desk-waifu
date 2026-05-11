# desk-waifu 文字 Tips 重设计 PRD

**版本**：v1.0 · 2026-05-10
**作者**：（PRD 由产品提出，本文档为最终对齐版）
**状态**：已确认变更，待实现
**关联文件**：`hooks/bubble-writer.sh`、`hammerspoon/desk-waifu.lua`、`~/.desk-waifu/bubble`

---

## 1. 背景与问题

当前 desk-waifu 在桌面右下角浮窗上方渲染单条 GLM 生成的台词气泡。线上观察到两类问题：

**P1 · 截断异常**
长 prompt 在受限宽度下被硬切，末尾出现孤立字符（截图中的 `❓`）。根因不是编码错误，是渲染端按字节硬截，恰好切在 emoji 边界，触发字符 fallback。

**P2 · 双事件视觉混乱**
当 `UserPromptSubmit`（用户提问）与 `PreToolUse`（Claude 即将执行 Fetch 等）几乎同时触发时，两条信息被塞进同一个气泡，仅以 `💬` / `🌐` emoji 区分。视觉上像一段话的两行，不像两个独立事件——主次不明、来源不明。

**P3 · 原 PRD Hook 清单不准**
产品同学列了 21 个 Claude Code Hook 事件，经核对官方文档（https://docs.claude.com/en/docs/claude-code/hooks），全部真实存在，但**官方实际共 29 个事件**。同时 21 个全开会导致 tips 闪烁、信噪比低。

---

## 2. 目标与非目标

### 2.1 目标
- ✅ 修复 P1：永不裁字符中段，气泡自动撑高
- ✅ 修复 P2：用户提问与 Claude 动作分两个独立气泡，左右分栏
- ✅ 修复 P3：Hook 事件订阅收敛到 5 核心 + 2 高优先级打断式
- ✅ 给出像素级视觉规范，前端可直接实现

### 2.2 非目标
- ❌ 不动 GIF 状态机（state-writer.sh 不变）
- ❌ 不做气泡内 Markdown 渲染、不做超链接点击
- ❌ 不做 Notification Center 集成
- ❌ 不动 GLM 限流逻辑（单 slot + 8s gap 保留）

---

## 3. Hook 事件清单（修订版）

### 3.1 官方 Hook 事件全集（29 个，仅供参考）

| 类别 | 事件 |
|---|---|
| 会话级 | `SessionStart`、`Setup`、`SessionEnd`、`InstructionsLoaded` |
| 用户交互 | `UserPromptSubmit`、`UserPromptExpansion`、`Stop`、`StopFailure` |
| 工具执行 | `PreToolUse`、`PermissionRequest`、`PermissionDenied`、`PostToolUse`、`PostToolUseFailure`、`PostToolBatch` |
| 代理/任务 | `SubagentStart`、`SubagentStop`、`TaskCreated`、`TaskCompleted`、`TeammateIdle` |
| 文件/配置 | `FileChanged`、`CwdChanged`、`ConfigChange` |
| 上下文 | `PreCompact`、`PostCompact` |
| Worktree | `WorktreeCreate`、`WorktreeRemove` |
| MCP | `Elicitation`、`ElicitationResult` |
| 通知 | `Notification` |

> 原 PRD 21 个事件全部真实存在；漏列 8 个：`Setup`、`InstructionsLoaded`、`UserPromptExpansion`、`TeammateIdle`、`WorktreeCreate`、`WorktreeRemove`、`Elicitation`、`ElicitationResult`。

### 3.2 实际订阅（v1.0 收敛到 5+2）

**核心 5 个**（决定气泡内容主流量）：

| Hook | 时机 | 气泡示例 | 渠道 |
|---|---|---|---|
| `UserPromptSubmit` | 用户回车后、Claude 处理前 | "收到，开始做 xxx" | user |
| `PreToolUse` | 工具执行前 | "查看 hooks.md" / "运行 npm test" | claude |
| `PostToolUse` | 工具成功后 | （静默，仅状态机用） | — |
| `PostToolUseFailure` | 工具失败后 | "Read 失败了，要不要看下" | claude |
| `Stop` | 本轮回复结束 | "完成啦，主人验收" | claude |

**高优先级打断 2 个**（同时触发桌宠 supervise 状态 + 醒目气泡）：

| Hook | 用途 |
|---|---|
| `Notification` | Claude 等输入 / 等授权 |
| `PermissionRequest` | 危险操作待批准 |

**v1.0 明确不订阅**（信噪比低或与 v1 场景无关）：
`SessionStart`、`SessionEnd`、`SubagentStart/Stop`、`TaskCreated/Completed`、`PreCompact/PostCompact`、`FileChanged`、`CwdChanged`、`ConfigChange`、`Setup`、`InstructionsLoaded`、`UserPromptExpansion`、`TeammateIdle`、`WorktreeCreate/Remove`、`Elicitation/ElicitationResult`、`StopFailure`、`PostToolBatch`、`PermissionDenied`。

> 所有 Hook 都收到通用字段：`session_id`、`transcript_path`、`cwd`、`permission_mode`、`hook_event_name`、`effort`。重点字段：`UserPromptSubmit.prompt`、`PreToolUse.tool_name`、`PreToolUse.tool_input`、`PostToolUse.tool_response`、`Notification.message`。

---

## 4. 视觉设计：聊天分栏式

### 4.1 整体布局

```
                    ╭──────────────────────────╮
                    │ desk-waifu 阅读项目代码  │
                    │ 的提交,我们的桌面助手的  │
                    │ 文字 tips 提示效果很差…  │
                    ╰──────────────────────╮ 💬│
                                            ╰──╯
  ╭──╮
  │🌐╭──────────────────────╮
  ╰──╯ Fetch                │
      │ code.claude.com/…   │
      ╰──────────────────────╯
```

- **用户气泡**：右对齐，主色背景（暖），尾巴在右下
- **Claude 气泡**：左对齐，中性灰背景（冷），尾巴在左下，字号小一号
- 二者**视觉权重不对称**：用户气泡更显眼（主输入），Claude 气泡更克制（动作流水）

### 4.2 像素规范

| 维度 | 用户气泡 | Claude 气泡 |
|---|---|---|
| 容器宽度 | 320–360px 固定 | 同左 |
| max-width | 85% 容器 | 75% 容器 |
| 对齐 | 右 | 左 |
| 背景色 | 主色 70% 不透明（建议 `#6B7AFF` × 0.7） | `#2A2A2E` × 0.5 |
| 字号 | 14px | 13px |
| 字色 | `#FFFFFF` | `#D0D0D5` |
| 圆角 | 12px，右下 4px（小尾巴） | 12px，左下 4px |
| Avatar | `💬` 右下浮标 | 左上浮标，按工具变（见 4.3） |
| 内边距 | 10px × 14px | 8px × 12px |
| 气泡间距 | 8px；同方连续多条 → 4px | 同左 |

### 4.3 Claude 气泡的 Avatar 字典

| 工具类型 | Avatar |
|---|---|
| Read / Grep / Glob | `📖` |
| Edit / Write / MultiEdit | `✏️` |
| Bash | `⚙️` |
| WebFetch / WebSearch | `🌐` |
| Task / Agent | `🤖` |
| Notification（打断式） | `❗` |
| PermissionRequest（打断式） | `🔐` |
| Stop（回合结束） | `✅` |
| 其它 | `🔧` |

### 4.4 内容规则

**用户气泡**
- 完整 prompt 不截断
- 自动撑高，无最大行数限制
- 仅渲染纯文本，emoji 保留

**Claude 气泡**
- 第一行：工具名（加粗）
- 第二行：参数缩写
  - URL → `host/…/末段文件名`（例：`code.claude.com/…/hooks.md`）
  - 文件路径 → `…/parent/file.ext`
  - Bash → 命令前 40 字符 + `…`
- 失败状态：整气泡边框变红 + 末尾 `❌`

### 4.5 截断规则（解决 P1）

**默认：不截断，自动撑高。**

如果超出屏幕高度（罕见极端 case）才允许截断，规则：
1. 按 grapheme 截（不按字节、不按 codepoint）
2. 末尾追加 `…`
3. 绝对禁止：在 emoji 中段、surrogate pair 中段、组合字符中段切

实现建议：JS 端用 `Intl.Segmenter`，Lua 端用 `utf8.len` + `utf8.offset`。

### 4.6 生命周期与动效

| 阶段 | 行为 |
|---|---|
| 出现 | fade-in 150ms + 上滑 4px |
| 工具进行中 | Claude 气泡右侧显示 ⏳ 微动画 |
| PostToolUse 成功 | ⏳ → ✓ 闪一下 200ms |
| PostToolUseFailure | 边框 red、末尾追加 `❌`、停留时间延长至 8s |
| 消失 | 5s 无新事件 → fade-out（可在 config 改） |

### 4.7 叠加策略

- 同时最多显示 **3 条**；超过则最早的先 fade-out
- 用户新 prompt 进来 → **清空所有未消失的 Claude 气泡**（标志新一轮的开始）
- Notification / PermissionRequest 是**置顶不消失**，直到用户处理或下一个 UserPromptSubmit 到来

---

## 5. 数据契约

### 5.1 气泡文件格式（升级）

当前格式：
```
<ts>\t<line>
```
仅支持单条、单渠道。

**新格式**（向前兼容旧 reader）：
```
<ts>\t<channel>\t<avatar>\t<line>[\t<sub_line>]
```

字段：
- `ts`：unix 秒，单调递增
- `channel`：`user` | `claude` | `alert`
- `avatar`：单个 emoji，见 §4.3
- `line`：主文本（用户气泡为完整 prompt；Claude 气泡为工具名）
- `sub_line`：可选第二行（Claude 气泡的参数缩写）

旧 reader 看到多余字段会忽略；新 reader 看到旧格式（只有 2 字段）按 `claude` 渠道、avatar `🔧`、无 sub_line 渲染。

### 5.2 文件位置（不变）
- `~/.desk-waifu/bubble`：当前气泡（覆盖写）
- `~/.desk-waifu/bubble.log`：debug 日志（DESK_WAIFU_DEBUG=1）

### 5.3 多气泡如何在单文件下表达

v1.0 决策：**仍用单文件 `bubble`，append 模式 + Lua 端读末 N 行**。
- bubble-writer.sh 每次写一行（append `>>`）
- Lua pathwatcher 读末尾 3 行渲染
- 文件超 200 行时 truncate 前 100 行（在 writer 里做）

> 备选方案（v2 再考虑）：分文件 `bubble.user` / `bubble.claude` / `bubble.alert`。v1 单文件简单够用。

---

## 6. 实现拆分

### 6.1 hooks/bubble-writer.sh 改动

| 当前 | 目标 |
|---|---|
| 写 `<ts>\t<line>`（覆盖） | 写新 5 字段格式（append） |
| 仅处理 4 事件 | 增加 `PreToolUse`、`PermissionRequest` 分支 |
| 无 channel 概念 | UserPromptSubmit→user / 其余→claude / Notification+PermissionRequest→alert |
| GLM prompt 单一 SYS | 按 channel 分 3 套 SYS（user 不调 GLM，原样回显 prompt；claude 走 GLM；alert 走 GLM） |
| 文件覆盖 | 文件 append + 200 行 trim |

**关键决策**：用户气泡**不调 GLM**，直接把 `prompt` 字段写入气泡。理由：用户已经看过自己输的内容，GLM 改写是浪费 token 且可能改错语义；气泡作用是"回放一下你刚说了啥"，原样最准。

### 6.2 hammerspoon/desk-waifu.lua 改动

- 解析新 5 字段格式（向前兼容 2 字段）
- 维护一个最多 3 条的 bubble 队列
- 按 channel 决定 anchor（user→右、claude→左、alert→置顶居中）
- 实装 §4.6 生命周期动效
- §4.5 截断规则（用 `utf8.offset` 定位 grapheme 边界）

### 6.3 配置入口

`~/.desk-waifu/config.lua`（可选，缺则用默认）：
```lua
return {
  width = 340,
  max_visible = 3,
  fade_after_ms = 5000,
  fade_after_ms_alert = -1,    -- 不自动消失
  user_bubble_color = "#6B7AFF",
  claude_bubble_color = "#2A2A2E",
}
```

---

## 7. 验收标准

| # | 标准 | 验证手段 |
|---|---|---|
| A1 | 喂入 `UserPromptSubmit` 含 400 字 prompt 的 JSON，气泡右侧完整显示，无截断 | `echo '{"hook_event_name":"UserPromptSubmit","prompt":"<400字>"}' \| bubble-writer.sh` |
| A2 | 喂入 `PreToolUse` + `tool_name=WebFetch`，气泡左侧出现 `🌐 Fetch / host/…/file` | 同上 |
| A3 | 喂入 `PostToolUseFailure`，气泡边框变红、末尾 `❌`、停留 ≥8s | 同上 |
| A4 | 100 字以上 prompt 含末尾 emoji，截断规则触发时不出现孤立 `❓` | 人造 case |
| A5 | 同时触发 UserPromptSubmit + PreToolUse，看到两个独立气泡（左右分栏），不挤在同一个框 | 主流程实跑 |
| A6 | 4 个气泡连续到达，最早的 fade-out，桌面只剩 3 条 | 脚本批量喂 |
| A7 | 新 UserPromptSubmit 到达，已存在的 Claude 气泡全部 fade-out | 主流程实跑 |
| A8 | Notification 气泡不自动消失，直到下一个 UserPromptSubmit | 主流程实跑 |
| A9 | bubble-writer 对畸形 JSON / 缺字段 / 空 stdin 静默退出，不阻塞 Claude Code | `echo '' \| bubble-writer.sh` 等 5 种 case |
| A10 | 旧 2 字段格式的 bubble 文件，新 Lua reader 仍能渲染（向前兼容） | 手写一行旧格式 |

**悲观偏置**：A1-A10 任何一条没亲手跑通 = 未完成。

---

## 8. 风险与回退

| 风险 | 缓解 |
|---|---|
| GLM 限流挤占 PreToolUse 高频调用 | PreToolUse 不调 GLM，直接用工具名+参数渲染（见 §6.1）。GLM 仅给 Stop/Notification/PostToolUseFailure 这种"需要拟人化"的事件用 |
| append 模式导致文件无限增长 | bubble-writer 内置 200 行 trim |
| Lua pathwatcher append 写入触发频率过高 | Lua 端 debounce 100ms |
| 旧用户升级后 Lua 没更新，新格式渲染崩 | 新格式向前兼容旧 reader（旧 reader 忽略多余字段）；旧格式向后兼容新 reader（§5.1） |

---

## 9. 后续（v2 候选，本期不做）

- 气泡内 Markdown 渲染（代码块、链接）
- 工具流水折叠（连续 N 个 Read 折成一条 "📖 ×5"）
- SubagentStart/Stop 子任务气泡
- TaskCreated/Completed Todo 卡片
- Notification 集成 macOS 原生通知中心
- 多文件分渠道（bubble.user / bubble.claude / bubble.alert）
- 气泡点击查看完整内容 / 复制
- 自定义 SYS prompt（让用户挑助手人格）

---

## 附录 A：Hook 事件 → 气泡 channel 映射

```
UserPromptSubmit       → channel=user,   avatar=💬,  无 GLM,直接回显 prompt
PreToolUse             → channel=claude, avatar=按工具,无 GLM,模板渲染
PostToolUse(success)   → 不发气泡(状态机用)
PostToolUseFailure     → channel=claude, avatar=❌, GLM 拟人化
Stop                   → channel=claude, avatar=✅, GLM 拟人化
Notification           → channel=alert,  avatar=❗, GLM 拟人化,置顶
PermissionRequest      → channel=alert,  avatar=🔐, GLM 拟人化,置顶
```

## 附录 B：变更日志

- v1.0 (2026-05-10) 首版，对齐产品 PRD 修订点 P1/P2/P3
