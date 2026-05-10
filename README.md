# desk-waifu

> 一个会陪你写代码的 chibi 桌面伴侣。Claude Code 在干什么，她就做什么。

<p align="center">
  <img src="assets/banner.gif" alt="9 states demo" width="100%"/>
</p>

<p align="center">
  <a href="https://github.com/cfrs2005/desk-waifu/releases"><img src="https://img.shields.io/github/v/release/cfrs2005/desk-waifu?include_prereleases" alt="release"/></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/cfrs2005/desk-waifu" alt="license"/></a>
  <img src="https://img.shields.io/badge/platform-macOS-black" alt="macos"/>
  <img src="https://img.shields.io/badge/needs-Hammerspoon-ff69b4" alt="hammerspoon"/>
  <img src="https://img.shields.io/badge/agent-Claude%20Code-7c3aed" alt="claude code"/>
</p>

`desk-waifu` 是一个 macOS 桌面浮窗，根据 [Claude Code](https://claude.com/claude-code) 当前的工作状态切换 GIF 动画。它写代码她就敲键盘，报错了她就摊手，编译跑着她就抱进度条。

整套架构非常轻：**Claude Code hooks → 写一个状态名到文件 → Hammerspoon 监听文件变更 → 切动画**。三段彼此解耦，挂哪段都不会卡 CLI。

## 这是什么 / 不是什么

✅ macOS + Claude Code + Hammerspoon 的桌面浮窗
✅ 根据 hook 事件自动切换 9 种动画
✅ 完全本地，零网络
✅ 素材可替换（你的二次元老婆 / 自家吉祥物 / 公司 mascot）

❌ 不是 Claude Code 官方的 `/buddy`（那是愚人节彩蛋且只能选预置物种）
❌ 不支持 Linux/Windows（Hammerspoon 是 mac 独占）
❌ 不发声、不弹提醒、不抢焦点

## 30 秒装上

```bash
# 1. 装依赖
brew install --cask hammerspoon
brew install jq

# 2. 启动 Hammerspoon 一次，授权辅助功能（系统设置 → 隐私与安全 → 辅助功能）

# 3. 装 desk-waifu
git clone https://github.com/<your-name>/desk-waifu.git
cd desk-waifu
./scripts/install.sh
```

装完会出现在屏幕右下角眨眼。打开 Claude Code 跑一句 `ls`，她就开始动了。

## 状态映射

| 状态 | 触发 | 动作 |
|---|---|---|
| `sleep` | SessionStart / SubagentStop / 默认 fallback | 趴枕头 ZZZ |
| `coding` | UserPromptSubmit / PreToolUse(Edit/Write/普通 Bash) / PostToolUse 成功 | 敲代码（每 ~12 秒随机切到 fix_bug 拧扳手）|
| `peek` | PreToolUse + Read/Grep/Glob/LS/WebFetch/只读 Bash | 探出窗口偷看 |
| `loading` | PreToolUse + 安装/构建命令 | 抱进度条 |
| `error_shrug` | PostToolUse + exit_code != 0 | 举 ERROR 牌摊手 |
| `celebrate` | Stop（一轮回话结束）| 跳 100% 庆祝；**保持 60 秒后自动转 sleep** |
| `supervise` | Notification（等批准）/ TodoWrite / Task | 叉腰盯着 |
| `fix_bug` | coding 状态下随机轮播（不直接由 hook 触发） | 拿扳手修 bug |

**核心语义**：

- **没事 = 睡（`sleep`）** —— 你不发言、Claude Code 不在干活，她就趴在那。
- **干活 = 敲代码（`coding`，每 12 秒随机轮播敲键盘 ⇄ 修 bug）** —— 任何 Claude Code 活动都是这状态。
- **结束 = 庆祝 1 分钟（`celebrate`→`sleep`）** —— 一轮回话结束跳跃 60 秒，然后自己回去睡。
- **失联自救（idle watchdog）** —— 任何活跃状态超过 3 分钟没新事件，自动降级到 sleep。会话异常断开 / 你走开了，她不会卡住。

完整规则在 [`hooks/state-writer.sh`](hooks/state-writer.sh)，可调参数（写到 `~/.desk-waifu/config.json`）：

```json
{
  "celebrate_hold": 60,
  "variant_period": 12,
  "idle_threshold": 180,
  "idle_check":     30
}
```

## 手动控制

```bash
echo coding > ~/.desk-waifu/state    # 切到敲代码
echo sleep  > ~/.desk-waifu/state    # 让她睡觉
```

热键（默认）：

| 组合 | 行为 |
|---|---|
| ⌘⌥P | 显示 / 隐藏 |
| ⌘⌥; | 切换屏幕角落（右下→左下→左上→右上） |
| ⌘⌥R | 重载 |

## 自定义素材

替换 `~/.desk-waifu/gifs/*.gif` 即可，文件名要和状态名一一对应：

```
idle_blink.gif  coding.gif       fix_bug.gif
error_shrug.gif loading.gif      celebrate.gif
peek.gif        sleep.gif        supervise.gif
```

GIF 透明背景效果最佳。本仓库自带的 9 张是 chibi 风格妹子；想换成猫猫狗狗自便。

## 配置

在 `~/.desk-waifu/config.json`（首次运行后可创建）调整：

```json
{
  "size": 240,
  "margin": 20,
  "corner": "bottom-right",
  "level": "floating"
}
```

`level` 设为 `"popUpMenu"` 会更高优先级（盖住绝大多数普通窗口）。

## 调试

```bash
# 打开 hook 日志
DESK_WAIFU_DEBUG=1   # 在 Claude Code 启动环境里设
tail -f ~/.desk-waifu/state-writer.log

# 手动触发 hook 脚本测试映射
echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response_exit_code":1}' \
  | ~/.desk-waifu/state-writer.sh && cat ~/.desk-waifu/state
# → error_shrug
```

## 架构

```
Claude Code  ──hooks──►  state-writer.sh  ──atomic write──►  ~/.desk-waifu/state
                                                                     │
                                                                     ▼
                                                    Hammerspoon pathwatcher
                                                                     │
                          ┌──────────────────────────────────────────┘
                          ▼
                ~/.desk-waifu/viewer.html  ──file:// (same-origin)──►  gifs/<state>.gif
                          ▲
                          │
                  hs.webview:url("file://...viewer.html")
```

三段都是单向 fire-and-forget：hook 失败 / Lua crash / Hammerspoon 没开都不影响 Claude Code。

> 为什么要落一个 `viewer.html`？因为 `hs.webview:html(string, baseURL)` 加载的 HTML 算 `about:blank` 来源，从那去 `file://` 加载 GIF 会被 WKWebView 同源策略拦掉。把 HTML 写成磁盘文件再用 `:url("file://...")` 加载，HTML 和 GIF 同 `file://` 来源，限制就过了。

## FAQ / Troubleshooting

### 安装完没看见浮窗

按这个顺序排：

1. **Hammerspoon 启动了吗？** `pgrep -lf Hammerspoon` 应有进程。没启就 `open -a Hammerspoon`
2. **辅助功能授权了吗？** 第一次启动 Hammerspoon 会弹窗，去 *系统设置 → 隐私与安全 → 辅助功能* 给 Hammerspoon 打勾。**不授权热键不生效但 webview 还能显示**——所以即便你没授权也应该看见浮窗，看不见说明还有别的问题
3. **Hammerspoon Console 有报错吗？** 菜单栏 🔨 → Console，搜 `desk-waifu`。正常应看到 `[desk-waifu] started, state=idle_blink`
4. **GIF 真的拷过去了吗？** `ls ~/.desk-waifu/gifs/` 应该有 9 个 .gif
5. **viewer.html 写出来了吗？** `cat ~/.desk-waifu/viewer.html` 应是 HTML 内容
6. **state 文件存在吗？** `cat ~/.desk-waifu/state`

### 浮窗出来了但 GIF 比例不对（图被裁掉一部分）

默认浮窗是 240×240 正方形，但本仓库自带的 chibi GIF 是 434×724（高瘦比）。`object-fit:contain` 会自动适配，但有些情况下显示偏小。改 `~/.desk-waifu/config.json`（不存在就创建）：

```json
{ "size": 280, "margin": 20, "corner": "bottom-right" }
```

然后按 ⌘⌥R 重载。

如果你换了自己的素材，**调整 `size` 大致匹配你 GIF 的最大边**就行。

### 浮窗一直在最上层挡视线

把 `level` 降到 floating（默认）。如果你想让她**穿透**任何窗口（连全屏视频也盖住），改成 `popUpMenu`：

```json
{ "level": "popUpMenu" }
```

### Claude Code 跑了但状态不变

```bash
# 1. 看 settings.json 里 hook 真的注册上了
jq '.hooks | keys' ~/.claude/settings.json
# 应该看到 PreToolUse / PostToolUse / 等

# 2. 手动喂个事件给 hook 脚本
echo '{"hook_event_name":"PreToolUse","tool_name":"Edit"}' | ~/.desk-waifu/state-writer.sh
cat ~/.desk-waifu/state   # 应该是 coding

# 3. 打开 hook 调试日志
DESK_WAIFU_DEBUG=1   # 在启动 Claude Code 的 shell 里 export
tail -f ~/.desk-waifu/state-writer.log
```

如果 (1) 没注册：重新跑 `./scripts/install.sh`。
如果 (2) 状态对但 (3) 没日志：Claude Code 进程没继承到 `DESK_WAIFU_DEBUG` 环境变量；或 hook 根本没被 Claude Code 调用——检查 settings.json 路径是 user 级（`~/.claude/settings.json`）还是 project 级（`.claude/settings.json`）。

### 想换自己的素材

只需把 `~/.desk-waifu/gifs/*.gif` 替换。文件名必须严格对应这 9 个状态：

```
idle_blink coding peek loading fix_bug
error_shrug celebrate supervise sleep
```

GIF 透明背景效果最好。可以参考 [`assets/gifs/make_gifs.py`](https://github.com/cfrs2005/desk-waifu)（或本仓库 `2026-05-10/make_gifs.py` 旧版）从精灵图切帧生成。

### 不想再让她出现一会儿

```bash
echo sleep > ~/.desk-waifu/state    # 切到睡觉动画
# 或
⌘⌥P                                  # 直接隐藏（再按一次显示）
```

完全停止：在 Hammerspoon Console 跑：

```lua
require("desk-waifu").stop()
```

### 卸载后再装回来

```bash
./scripts/uninstall.sh --yes
./scripts/install.sh
```

uninstall 用 `__desk_waifu` 标签精准删 hook 条目，不会动你的其它 hook 配置。

### 多显示器场景

`corner` 始终基于 `hs.screen.mainScreen()`（主显示器）。要让浮窗跟随活动屏幕，目前需要自己改 Lua（PR welcome）。

### 我用的不是 macOS

Hammerspoon 是 mac 独占。但你可以用 [`docs/AGENTS.md.example`](docs/AGENTS.md.example) 那份**纯 markdown 输出风格 fallback**——在 Cursor / Codex CLI / web chat 这类支持 markdown 图片渲染的客户端里，让 LLM 自己按状态贴 GIF。效果不如桌面浮窗准确（因为是模型自我标注 vs hook 真实事件），但能跨平台。

### Hammerspoon CLI (`hs -c`) 用不了

需要在 `~/.hammerspoon/init.lua` 头部加：

```lua
require("hs.ipc")
```

然后 ⌘⌥R 重载 Hammerspoon。之后可以：

```bash
hs -c 'hs.reload()'                          # 远程重载
hs -c 'require("desk-waifu").cycle_corner()' # 远程切角
```

这是 Hammerspoon 自带能力，不是 desk-waifu 必需，但调试很方便。

## 卸载

```bash
./scripts/uninstall.sh
# 或 ./scripts/uninstall.sh --yes  跳过确认
```

会从 `~/.claude/settings.json` 干净地移除注入的 hook 条目（用 jq 按 `__desk_waifu` 标签精准删），并清掉 `~/.hammerspoon/desk-waifu.lua` 和 init.lua 里的 require。

## 兼容性

- macOS 12+
- Hammerspoon 0.9.100+
- Claude Code（任何支持 hooks 的版本）
- jq

## 致谢 / 灵感

- [limin112/claude-goal-skill](https://github.com/limin112/claude-goal-skill) 的目标续推方法论 —— 本项目用它驱动到完工
- Anthropic Claude Code `/buddy` 愚人节彩蛋 —— 给了"桌面宠物可以跟 CLI 联动"的启发

## License

MIT。素材（assets/gifs）可自由替换为你自己的；如果想保留默认素材但用于商业产品，请自行确认风格授权。
