# desk-waifu

> 一个会陪你写代码的 chibi 桌面伴侣。Claude Code 在干什么，她就做什么。

<p align="center">
  <img src="assets/gifs/coding.gif" width="120" alt="coding"/>
  <img src="assets/gifs/fix_bug.gif" width="120" alt="fix_bug"/>
  <img src="assets/gifs/error_shrug.gif" width="120" alt="error"/>
  <img src="assets/gifs/celebrate.gif" width="120" alt="celebrate"/>
  <img src="assets/gifs/supervise.gif" width="120" alt="supervise"/>
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
| `idle_blink` | SessionStart / Stop / 默认 | 站着眨眼 |
| `coding` | PreToolUse + Edit/Write/MultiEdit/普通 Bash | 敲代码 |
| `peek` | PreToolUse + Read/Grep/Glob/LS/WebFetch/只读 Bash | 探出窗口偷看 |
| `loading` | PreToolUse + 安装/构建命令 | 抱进度条 |
| `fix_bug` | （保留，可手动写入） | 拿扳手修 bug |
| `error_shrug` | PostToolUse + exit_code != 0 | 举 ERROR 牌摊手 |
| `celebrate` | PostToolUse + 测试命令成功 | 跳 100% 庆祝 |
| `supervise` | Notification（等批准）/ TodoWrite / Task | 叉腰盯着 |
| `sleep` | （保留，可手动写入） | 趴枕头 ZZZ |

完整规则在 [`hooks/state-writer.sh`](hooks/state-writer.sh)。

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
                                                                     ▼
                                                  hs.webview ＋ <img src="…gif">
```

三段都是单向 fire-and-forget：hook 失败 / Lua crash / Hammerspoon 没开都不影响 Claude Code。

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
