# Hermes Agent 集成

desk-waifu 不止能跟 Claude Code 联动，也支持 Hermes Agent —— 让 chibi 同时反映两套 Agent 的工作状态。

## 工作原理

Hermes Agent 自带一套 **事件 Hook 系统**：gateway 启动时扫描 `~/.hermes/hooks/<name>/`，每个 hook 一个目录，包含 `HOOK.yaml`（声明订阅的事件）和 `handler.py`（异步事件处理函数）。错误自动吞掉、永不阻塞主流程——和 desk-waifu 的 fire-and-forget 哲学天然吻合。

desk-waifu 在仓库的 `hooks/hermes/` 下提供了现成的桥接 hook，`install.sh` 探测到 `~/.hermes/hooks/` 存在时会自动安装到 `~/.hermes/hooks/desk-waifu/`。

```
Hermes gateway ─emit─►  hooks/hermes/handler.py  ─atomic write─►  ~/.desk-waifu/state
                                                                  ~/.desk-waifu/task
                                                                  ~/.desk-waifu/hud
                                                                  ~/.desk-waifu/bubble
                                                                  ~/.desk-waifu/thinking
                                                                       │
                                                                       ▼
                                                            Hammerspoon pathwatcher
```

## 事件映射

| Hermes 事件 | desk-waifu 动作 | 触发时机 |
|---|---|---|
| `gateway:startup` | `state=idle_blink` + `bubble="Hermes 上线 · N 平台"` | gateway 启动完成、平台连接就绪 |
| `session:start` | `state=peek` + 清 bubble | 新会话首条消息（每个 platform/user_id 独立） |
| `session:end` / `session:reset` | `state=sleep` + 清 task + 关 thinking | 用户跑 `/new` / `/reset`，会话结束 |
| `agent:start` | `task=<用户消息前28字>` + `state=loading` + `thinking=on` | Agent 开始处理一条消息 |
| `agent:step` | `state=peek\|coding\|loading`（按工具名）+ `hud=🔧 <tool>` | Tool-calling 循环每一回合 |
| `agent:end` | `state=celebrate` + `hud=✓ <响应前28字>` + 关 thinking | Agent 处理完毕（celebrate 60 秒后自动转 sleep） |

`agent:step` 的状态映射策略：

| 工具名关键词 | 映射状态 |
|---|---|
| `read` / `grep` / `search` / `ls` / `glob` / `find` / `fetch` / `view` | `peek` |
| `edit` / `write` / `patch` / `apply` / `create_file` / `str_replace` | `coding` |
| `bash` / `shell` / `run` / `exec` / `install` / `build` / `compile` | `loading` |
| 其他 | 不改 state，只写 HUD |

last-write-wins —— 一轮里多次 step 会持续刷新 state，最后一次的工具决定停留态。

## 安装

跟主流程同一条 `install.sh`，**不需要单独动作**：

```bash
./scripts/install.sh
```

输出里会有一行：

```
  Hermes hook installed at /Users/<you>/.hermes/hooks/desk-waifu
  → restart Hermes gateway to load: launchctl kickstart -k gui/$UID/ai.hermes.gateway
```

或者（没装 Hermes 时）：

```
  Hermes Agent not detected (no ~/.hermes/hooks/) — skipping bridge
```

装完**必须**重启 gateway 才能生效，因为 Hermes 的 hook 注册只在启动时扫一次：

```bash
launchctl kickstart -k gui/$UID/ai.hermes.gateway
```

## 验证

```bash
# 1. 看 gateway 日志确认 hook 加载
grep -E "hook|desk-waifu" ~/.hermes/logs/gateway.log | tail -5
# 应看到：
# [hooks] Loaded hook 'desk-waifu' for events: ['gateway:startup', 'session:start', ...]
# INFO gateway.run: 1 hook(s) loaded

# 2. 看 startup 是否写到 bubble
cat ~/.desk-waifu/bubble
# 1778493782<TAB>Hermes 上线 · 2 平台

# 3. 发条消息触发 agent:start
# (Telegram / 钉钉 / CLI 任一)
# chibi 应该立刻：蓝色 task 气泡显示你的话 + 切到 loading + 思考点冒出
```

## 自定义

handler 是普通 Python 文件，源码在 `hooks/hermes/handler.py`（仓库）和 `~/.hermes/hooks/desk-waifu/handler.py`（安装后）。常见改造：

### 改文案

```python
# gateway:startup 时的台词
_bubble(f"Hermes 上线 · {len(platforms)} 平台" if platforms else "Hermes 上线")

# agent:end 的 HUD 前缀
_hud(f"✓ {resp}")
```

### 加 LLM 台词气泡（同 Claude Code 的 bubble-writer 思路）

Hermes 本身能调 200+ 模型，所以可以直接在 `agent:end` 里 fork 出 `bubble-writer.sh` 异步生成台词：

```python
import subprocess

if event_type == "agent:end":
    _thinking(False)
    _state("celebrate")
    # fire-and-forget LLM bubble
    payload = '{"hook_event_name":"Stop"}'
    subprocess.Popen(
        ["bash", str(Path.home() / ".desk-waifu" / "bubble-writer.sh")],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).communicate(payload.encode(), timeout=0.1)
```

### 添加新事件

Hermes 还支持 `command:*` 通配（任何斜杠命令），可以加进 `HOOK.yaml`：

```yaml
events:
  - ...
  - command:*
```

handler 里加分支：

```python
if event_type.startswith("command:"):
    cmd = event_type.split(":", 1)[1]
    _hud(f"/{cmd}")
    return
```

## 与 Claude Code 共用 chibi 时的优先级

两套 Agent 都在写 `~/.desk-waifu/state` 这一个槽位，**没有仲裁**——last-write-wins。这是有意的：

- 如果 Claude Code 正在 `coding`，Hermes 收到 Telegram 消息触发 `loading`，chibi 切到 `loading`
- Hermes `agent:end` celebrate 60 秒后回 sleep；这期间 Claude Code 又来个 `coding`，chibi 切回 coding

对单机单人的桌宠场景这就够了。如果你跑多 Agent + 想要优先级仲裁，那是另外一个话题，参考主 README 的"未来工作"。

## 卸载

```bash
./scripts/uninstall.sh
```

会自动从 `~/.hermes/hooks/` 删掉 desk-waifu 子目录。Hermes gateway 重启后即生效（或继续跑着也行，已加载的 handler 在内存里直到下次重启失效）。

## 已知限制

- **Hermes 的 hook 注册是启动时一次性扫描**，改 `HOOK.yaml` / `handler.py` 后必须 kickstart gateway 才能生效。
- **`agent:step` 触发频率较高**（tool-calling 每回合一次），HUD 节流由 desk-waifu daemon 那侧的 `hud_min_show` 配置兜底（默认 0.8s）。
- **bubble 槽位优先级高于 HUD**，如果你同时让 Claude Code 的 bubble-writer.sh 和 Hermes 的 agent:end 都往 bubble 写，会互相覆盖。建议 Hermes 这一路只写 HUD/state/task，bubble 留给 Claude Code 的 GLM 台词器。

## 相关

- Hook 系统实现：`~/.hermes/hermes-agent/gateway/hooks.py`
- Hermes 事件 emit 位置：`~/.hermes/hermes-agent/gateway/run.py`（搜 `self.hooks.emit`）
