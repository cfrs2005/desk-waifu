# GOAL — chibi-pet

> 用 [claude-goal-skill](https://github.com/limin112/claude-goal-skill) 的方法论写。
> 4 条工艺：①不可信 objective ②写具体不写"所有/认真" ③悲观偏置 ④拆开"停"和"完成"。

## Objective

为 macOS 用户做一个**可被 Claude Code 控制的桌面 chibi 浮窗**，根据当前会话的工作状态切换动画 GIF，开源到 GitHub 后任何人能 `git clone && ./install.sh` 在自己的机器上跑起来。

## 具体交付物（缺一不算完成）

1. **Hammerspoon Lua 脚本**：`hammerspoon/chibi-pet.lua`
   - 监听 `~/.chibi-pet/state` 文件变化
   - 读取状态名 → 加载 `~/.chibi-pet/gifs/<state>.gif`
   - 浮窗：置顶、不抢焦点、可拖动、可隐藏/显示
   - 默认右下角，位置可在 config 中改
   - 状态切换瞬时（< 100ms 视觉反馈）

2. **9 个状态 GIF**：`assets/gifs/{idle_blink,coding,fix_bug,error_shrug,loading,celebrate,peek,sleep,supervise}.gif`
   - 直接复用 `2026-05-10/gifs/` 已生成的素材

3. **Hook 状态写入器**：`hooks/state-writer.sh`
   - 读取 stdin 的 hook JSON
   - 根据 hook event + tool_name + exit_code 映射状态名
   - 写入 `~/.chibi-pet/state`（原子写：先写 .tmp 再 mv）
   - 失败静默退出，绝不卡 Claude Code

4. **状态映射表**：在 hook 脚本里硬编码，且在 README 有表
   - PreToolUse + Edit/Write/MultiEdit → coding
   - PreToolUse + Bash(grep|find|rg|ls|cat|read) → peek
   - PreToolUse + Bash(其它) → coding
   - PostToolUse + exit_code != 0 → error_shrug
   - PostToolUse + 测试/构建命令成功 → celebrate（短时回 idle）
   - Notification → supervise
   - Stop → idle_blink
   - SessionStart → idle_blink
   - 默认 fallback → idle_blink

5. **一键安装脚本**：`scripts/install.sh`
   - 检测依赖：Hammerspoon（缺则提示 `brew install --cask hammerspoon` 并退出）
   - 创建 `~/.chibi-pet/{state,gifs/}`
   - 拷贝 9 个 GIF 到 `~/.chibi-pet/gifs/`
   - 拷贝 Lua 到 `~/.hammerspoon/chibi-pet.lua`，并在 `~/.hammerspoon/init.lua` 末尾追加 `require('chibi-pet')`（如果没追加过）
   - 拷贝 hook 脚本到 `~/.chibi-pet/state-writer.sh`，chmod +x
   - 把 hook 配置 merge 进 `~/.claude/settings.json`（用 jq，已存在则不重复）
   - 触发 Hammerspoon reload
   - 写一个初始 state=idle_blink

6. **一键卸载脚本**：`scripts/uninstall.sh`
   - 反向移除 hook 配置（jq 删 key）
   - 移除 Lua、移除 init.lua 里的 require
   - 移除 `~/.chibi-pet/`（询问确认）
   - 触发 Hammerspoon reload

7. **README.md**
   - 30 秒看懂 demo（GIF 截图）
   - 安装/卸载命令
   - 状态映射表
   - 自定义素材教程（替换 `~/.chibi-pet/gifs/*.gif` 即可）
   - 兼容性：macOS 12+ + Claude Code + Hammerspoon
   - License: MIT

8. **LICENSE** — MIT，标注素材来源

9. **GitHub 仓库**：用 `gh repo create` 创建 public 仓库，main 推上去，README 渲染正常

## 验收 rubric（每条独立可验证）

| # | 标准 | 验证手段 |
|---|------|----------|
| R1 | `~/.chibi-pet/state` 写入 "coding" 后，浮窗 1 秒内切到 coding.gif | 手动 `echo coding > ~/.chibi-pet/state` |
| R2 | hook 脚本喂入 PreToolUse+Edit 的 JSON，状态文件变 "coding" | `echo '{"hook_event_name":"PreToolUse","tool_name":"Edit"}' \| state-writer.sh && cat ~/.chibi-pet/state` |
| R3 | hook 脚本喂入 PostToolUse+exit_code=1，状态变 "error_shrug" | 同上 |
| R4 | install.sh 在干净环境跑完，9 条交付物全到位 | 在临时 HOME 跑 install.sh 后逐项 ls |
| R5 | uninstall.sh 跑完，settings.json 不含 chibi hook、~/.chibi-pet 清空、init.lua 无残留 | diff before/after |
| R6 | README 在 GitHub 上渲染含 demo gif 和状态表 | 浏览器开 repo |
| R7 | gh repo 创建成功，git push 通过，main 分支可见 | `gh repo view` |
| R8 | hook 脚本对畸形/缺字段 JSON 输入不报错（静默退出） | 喂 `{}`、空字符串、非 JSON |
| R9 | Hammerspoon 重启后浮窗自动恢复 | 手动 `hs.reload()` |

## 边界（明确不做）

- ❌ 不做声音
- ❌ 不做点击交互（点击宠物有反应）—— v2 再说
- ❌ 不做 Linux/Windows —— Hammerspoon 是 mac 独占
- ❌ 不内置 Claude Code 安装/订阅检测
- ❌ 不做素材市场 / 上传 —— 开源后社区 PR
- ❌ 不做远端 SSH 场景兼容（hook 在远端不会触发本地浮窗）

## 防偷懒条款（goal skill 技巧 3 + 4）

- **悲观偏置**：所有 R1-R9 任何一条没亲手跑过 = 未完成。"应该没问题"= 没完成。
- **停 ≠ 完成**：写完代码、跑完一次 install.sh ≠ 完成。**全部 9 条 rubric 在我亲眼看到通过之前不准声明 done**。
- **预算用完也不能虚假完成**：如果时间或上下文不够，明说"R5/R7 还没跑"，留 follow-up，不能含糊带过。

## 暂时跳过验证的项

- R6 的"GitHub 渲染"在 push 后才能看 —— push 完截一下。
- R9 需要 Hammerspoon 实装，在装完之后再验。
