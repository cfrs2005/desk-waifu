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

`desk-waifu` 是一个 macOS 桌面浮窗，根据 [Claude Code](https://claude.com/claude-code) 当前的工作状态切换 GIF 动画。它写代码她就敲键盘，报错了她就摊手，编译跑着她就抱进度条。可选挂上小模型（智谱 GLM-4-Flash 之类）做"傲娇台词气泡"，回合结束/错误/需要审批时她还会吐一句槽。

整套架构非常轻：**Claude Code hooks → 写一个状态名到文件 → Hammerspoon 监听文件变更 → 切动画**。可选的 LLM 旁路在同一个 hook 里 fork 出去后台调用，永远不阻塞 Claude Code。三段彼此解耦，挂哪段都不会卡 CLI。

## 这是什么 / 不是什么

✅ macOS + Claude Code + Hammerspoon 的桌面浮窗
✅ 根据 hook 事件自动切换 9 种动画
✅ 可拖动、多显示器自适应（每屏独立记忆位置）
✅ 可选 LLM 台词气泡（Stop / Notification / 报错时吐槽，用 GLM-4-Flash 等小模型即可，免费档够用）
✅ 默认完全本地零网络；气泡功能不配 `glm.env` 就完全不启用
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
| ⌘⌥; | 切换屏幕角落（右下→左下→左上→右上），并清掉**当前屏**的自定义位置 |
| ⌘⌥R | 重载 |

**拖动**（两条路径都行）：

- **触控板**：按住 ⌥(option)，指针滑过 waifu 就跟着走，松开 ⌥ 自动保存位置。不需要 force-click，也不依赖系统设置里的「三指拖移」。
- **鼠标**：左键按住浮窗直接拖。

松手/松 ⌥ 时按每屏 UUID 把相对偏移（百分比）写进 `~/.desk-waifu/config.json`。换分辨率仍然保位，浮窗跑出屏外会自动 clamp 回来。换显示器/插拔外显时 `hs.screen.watcher` 也会自动重定位。

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
  "level": "floating",
  "bubble_hold": 6,
  "bubble_max_width": 280,
  "bubble_font_size": 14,
  "positions": {
    "<screen-UUID-自动写入>": { "x_pct": 0.82, "y_pct": 0.78 }
  }
}
```

`level` 设为 `"popUpMenu"` 会更高优先级（盖住绝大多数普通窗口）。`positions` 由拖动自动维护，一般不用手改。

## 台词气泡（可选）

回合结束 / Claude 提醒 / 工具报错时，叫一个小模型用 ≤14 个汉字写一句傲娇 chibi 台词，浮窗顶上飘个气泡 6 秒就散。

**为什么这么挑事件？** GLM 免费档限速严，每次 PreToolUse 都打肯定刷爆。所以只挑三类**对人有用**的时刻说话：完工庆祝、需要审批、踩坑摊手。

### 接通智谱 GLM

1. 去 [bigmodel.cn](https://open.bigmodel.cn/) 注册，复制 API Key。
2. 把凭证写到 `~/.desk-waifu/glm.env`（**mode 600**，别提交到 git）：

```bash
cat > ~/.desk-waifu/glm.env <<'EOF'
GLM_API_KEY=你的key
GLM_MODEL=GLM-4-FlashX
GLM_ENDPOINT=https://open.bigmodel.cn/api/paas/v4/chat/completions
EOF
chmod 600 ~/.desk-waifu/glm.env
```

> ⚠️ 智谱**没有** `GLM-4.7-Flash` 这个 SKU，用了会一直请求超时。实际免费可用的是 `GLM-4-Flash` / `GLM-4-FlashX`。

3. 验证一下：

```bash
echo '{"hook_event_name":"Stop"}' | DESK_WAIFU_DEBUG=1 ~/.desk-waifu/bubble-writer.sh
cat ~/.desk-waifu/bubble
# 1778468756\t厉害了主人！
```

### 换别的小模型 / 自部署

`bubble-writer.sh` 用的是 **OpenAI 兼容** chat completions 协议，只要支持 `{messages, max_tokens, temperature}` 的端点都能直接换：DeepSeek、月之暗面、SiliconFlow、本地 vLLM/Ollama 均可。改 `glm.env` 里的 `GLM_ENDPOINT` / `GLM_MODEL` / `GLM_API_KEY` 三个变量即可。

### 改人设 / 改字数

直接编辑 `~/.desk-waifu/bubble-writer.sh` 里的 `SYS_PROMPT`。默认人设是傲娇守桌 chibi、≤14 汉字、不加标点。气泡显示时长改 `bubble_hold`。

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
Claude Code ──hooks──►  state-writer.sh ──atomic write──►  ~/.desk-waifu/state ──┐
                              │                                                   │
                              │ (Stop / Notification / 错误事件)                   │
                              ▼                                                   │
                       bubble-writer.sh ──curl GLM─►  ~/.desk-waifu/bubble  ──────┤
                       (后台 nohup, 永不阻塞)                                      │
                                                                                  ▼
                                                            Hammerspoon pathwatcher
                                                                                  │
                                       ┌──────────────────────────────────────────┘
                                       ▼                          ▼
                            ~/.desk-waifu/viewer.html       hs.canvas 气泡
                                       ▲
                              hs.webview:url("file://...")
```

三段都是单向 fire-and-forget：hook 失败 / GLM 限流 / Lua crash / Hammerspoon 没开都不影响 Claude Code。气泡功能没配 `glm.env` 时 `bubble-writer.sh` 直接 `exit 0`，整条旁路自然关闭。

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

两条路：

**A. 直接换 GIF（最简单）**

把 `~/.desk-waifu/gifs/*.gif` 替换成你自己的，文件名必须严格对应这 9 个状态：

```
idle_blink coding peek loading fix_bug
error_shrug celebrate supervise sleep
```

GIF 必须是**真透明**（GIF89a + 调色板透明索引），白底会很显眼。

**B. 从精灵图自动生成（推荐）**

往 `assets/source/` 放 9 张同名 PNG，每张是一行 N 帧的横向精灵图：

```
assets/source/
  idle_blink.png    # 6 frames horizontal strip
  coding.png        # 6 frames
  ...
```

然后跑：

```bash
pdm install                              # 装 Pillow
pdm run python scripts/make_gifs.py      # 全部重生成
pdm run python scripts/make_gifs.py celebrate  # 只生成某一个
./scripts/install.sh                     # 把新 GIF 推到 ~/.desk-waifu/gifs/
```

帧数 / 时长 / 是否回弹播放在 `scripts/make_gifs.py` 顶部的 `STATES` 表里调。

> 这个脚本用 **magenta-key** 算法保证 GIF 透明：把白底打上洋红色（#FF00FF）→ 量化到 255 色 → 强制 palette[255] = 洋红 → 在 GIF 头里标 transparency=255。这样无论你的素材多花哨，透明永远生效，比 PIL 默认的 RGBA→GIF 路径稳。

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

浮窗会按**鼠标所在屏**定位（不再用 `hs.screen.mainScreen()`，避免外显接入时 main 跳屏带歪位置）。每个屏幕的自定义位置按 UUID 单独存在 `config.positions`，插拔外显或换分辨率都能保留。

- 想恢复某屏到角落预设：把 waifu 拖到那块屏，按 ⌘⌥; 循环到想要的角，对应屏的自定义位置会被清掉。
- 想完全重置位置：删 `~/.desk-waifu/config.json` 里的 `positions` 字段，或整段删掉重启 Hammerspoon。

### 气泡不出现 / 一直没台词

```bash
# 1. 凭证文件在不在
ls -la ~/.desk-waifu/glm.env

# 2. 直接喂一个事件，看 bubble 文件有没有被写
echo '{"hook_event_name":"Stop"}' | DESK_WAIFU_DEBUG=1 ~/.desk-waifu/bubble-writer.sh
cat ~/.desk-waifu/bubble
tail ~/.desk-waifu/bubble.log

# 3. 直接打 endpoint 试连通性
. ~/.desk-waifu/glm.env
curl -sS --max-time 10 \
  -H "Authorization: Bearer $GLM_API_KEY" -H "Content-Type: application/json" \
  -d "{\"model\":\"$GLM_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":10}" \
  "$GLM_ENDPOINT"
```

常见返回：
- `1302` 速率限制 → 等一会再说，免费档很紧
- `1305` 容量过大 → 同上，或换 `GLM-4-Flash` / `GLM-4-FlashX`
- curl 一直 timeout → **大概率是模型名打错**（`GLM-4.7-Flash` 不存在，会一直 hang）

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
