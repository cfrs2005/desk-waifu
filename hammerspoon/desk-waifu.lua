-- desk-waifu — chibi 桌面伴侣，受 ~/.desk-waifu/state 与 ~/.desk-waifu/bubble 驱动
-- 安装位置: ~/.hammerspoon/desk-waifu.lua
-- 在 ~/.hammerspoon/init.lua 末尾追加: require('desk-waifu')

local M = {}

local DATA_DIR     = os.getenv("HOME") .. "/.desk-waifu"
local STATE_FILE   = DATA_DIR .. "/state"
local BUBBLE_FILE  = DATA_DIR .. "/bubble"
local HUD_FILE     = DATA_DIR .. "/hud"
local TASK_FILE    = DATA_DIR .. "/task"
local THINK_FILE   = DATA_DIR .. "/thinking"
local SPEECH_TICK  = DATA_DIR .. "/speech-tick.sh"
local GIFS_DIR     = DATA_DIR .. "/gifs"
local CONFIG_FILE  = DATA_DIR .. "/config.json"
local VIEWER_HTML  = DATA_DIR .. "/viewer.html"

local DEFAULTS = {
  size            = 240,
  margin          = 20,
  corner          = "bottom-right", -- 用于第一次出现 / 没保存过的屏幕
  level           = "floating",
  celebrate_hold  = 60,
  variant_period  = 12,
  idle_threshold  = 180,
  idle_check      = 30,
  bubble_hold     = 0,              -- 0 = sticky（不自动隐藏，被新台词替换或 sleep 时才走）
  bubble_max_width= 320,
  bubble_max_lines= 3,
  bubble_font_size= 14,
  speech_tick_period = 300,         -- 主动台词检查间隔（秒）
  hud_min_show      = 0.8,          -- 每条 HUD 至少显示秒数（节流，防闪烁）
  hud_hold_max      = 8,             -- HUD 后多久仍无新事件就淡出（秒）
  positions       = {},             -- { [screen_uuid] = { x_pct=, y_pct= } }
  hotkey_toggle   = { mods = {"cmd","alt"}, key = "p" },
  hotkey_cycle    = { mods = {"cmd","alt"}, key = ";" },
  hotkey_reload   = { mods = {"cmd","alt"}, key = "r" },
}

local VARIANTS = { coding = { "coding", "fix_bug" } }

-- 本地静态台词池：状态机切换时随机抽一句，5 秒短显，零网络零限速。
-- GLM 写到 ~/.desk-waifu/bubble 的 sticky 台词永远高优先级，会立刻覆盖静态台词。
-- sleep / idle_blink 故意留空：休息时不打扰。celebrate 也留空，让 GLM 来发挥。
local STATE_LINES = {
  coding      = { "敲敲敲", "代码行起来", "字符蹦跶", "tab 补全救我", "回车快充", "这一行有点意思" },
  peek        = { "让我瞅一眼", "翻翻文件", "啊这", "翻页中", "目录树爬一爬", "找找看" },
  loading     = { "等它编译", "进度条加油", "这段抱一会", "我数羊呢", "依赖装不完啊", "等啊等" },
  fix_bug     = { "扳手哪去了", "啧啧啧", "这 bug 谁种的", "重启大法好", "再读一遍", "嗯？" },
  supervise   = { "在监督呢", "盯着主人", "嗯哼", "你这步要小心", "看你的" },
  error_shrug = { "啊？！", "翻车了", "再来一次", "exit code 不太对劲", "嗯…重试" },
}

local config = {}
local webview
local user_canvas, claude_canvas, glm_canvas, bubble_canvas  -- bubble_canvas 留作旧 show_static_line 路径
local state_watcher, screen_watcher, light_tap, drag_tap
local cached_hw                          -- 拖动期缓存 webview:hswindow()，省 ObjC 桥
local last_move_at = 0
local MOVE_MIN_DT  = 1 / 90              -- 节流到 ~90Hz，主线程不堵
local current_state, current_screen_uuid
local revert_timer, variant_timer, idle_timer, bubble_timer, speech_timer
local thinking_canvas, thinking_anim_timer
local last_event_at, last_bubble_ts = 0, 0
local last_hud_ts, last_hud_shown_at = 0, 0
local last_task_ts = 0
local pending_hud_text, pending_hud_timer = nil, nil
local hud_fade_timer = nil
local task_text = nil   -- 持久任务条（UserPromptSubmit 写入，Stop 清空）
local hud_text  = nil   -- 当前 HUD 一行（800ms 节流，8s 自动清）
local glm_text  = nil   -- 当前 GLM persona 一行（sticky，下一条 GLM 或 sleep 清）
local drag = nil

-- ──────────────────────────────────────────────────────────────────
-- io helpers
-- ──────────────────────────────────────────────────────────────────
local function read_file(path)
  local f = io.open(path, "r"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

local function file_exists(path)
  local f = io.open(path, "r"); if f then f:close(); return true end; return false
end

local function deep_merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then
      deep_merge(dst[k], v)
    else
      dst[k] = v
    end
  end
end

local function load_config()
  config = {}
  for k, v in pairs(DEFAULTS) do
    if type(v) == "table" then config[k] = {}; for kk, vv in pairs(v) do config[k][kk] = vv end
    else config[k] = v end
  end
  local raw = read_file(CONFIG_FILE)
  if raw and raw ~= "" then
    local ok, data = pcall(hs.json.decode, raw)
    if ok and type(data) == "table" then deep_merge(config, data) end
  end
  config.positions = config.positions or {}
end

-- 只持久化「与默认值不同 / 运行时学到的」字段，避免把 DEFAULTS 烧进文件
-- 后续再改默认值时就不会被旧 config.json 卡住
local function save_config()
  local raw = read_file(CONFIG_FILE)
  local on_disk = {}
  if raw and raw ~= "" then
    local ok, data = pcall(hs.json.decode, raw)
    if ok and type(data) == "table" then on_disk = data end
  end
  -- positions 一定写回（来自拖动）
  on_disk.positions = config.positions
  -- 用户曾经显式覆盖过的字段保留；DEFAULTS 同值的字段不写
  for k, default_v in pairs(DEFAULTS) do
    if k ~= "positions" and on_disk[k] ~= nil then
      if type(default_v) ~= "table" and on_disk[k] == default_v then
        on_disk[k] = nil  -- 现场值等于默认值，移除让 DEFAULTS 接管
      end
    end
  end
  local ok, encoded = pcall(hs.json.encode, on_disk, true)
  if not ok then return end
  local f = io.open(CONFIG_FILE, "w")
  if f then f:write(encoded); f:close() end
end

-- ──────────────────────────────────────────────────────────────────
-- screen + framing
-- ──────────────────────────────────────────────────────────────────
local function pick_screen()
  -- 优先：鼠标所在屏；fallback：主屏
  local s = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  return s
end

local function corner_frame(screen)
  local sf = screen:frame()
  local s, m = config.size, config.margin
  local x, y
  if config.corner == "bottom-right" then
    x, y = sf.x + sf.w - s - m, sf.y + sf.h - s - m
  elseif config.corner == "bottom-left" then
    x, y = sf.x + m, sf.y + sf.h - s - m
  elseif config.corner == "top-right" then
    x, y = sf.x + sf.w - s - m, sf.y + m
  else
    x, y = sf.x + m, sf.y + m
  end
  return { x = x, y = y, w = s, h = s }
end

local function compute_frame()
  local screen = pick_screen()
  local uuid = screen:getUUID()
  current_screen_uuid = uuid
  local sf = screen:frame()
  local pos = config.positions[uuid]
  if pos and pos.x_pct and pos.y_pct then
    local s = config.size
    local x = sf.x + sf.w * pos.x_pct
    local y = sf.y + sf.h * pos.y_pct
    -- clamp 一下，防止屏幕换分辨率后跑出屏外
    if x < sf.x then x = sf.x end
    if y < sf.y then y = sf.y end
    if x + s > sf.x + sf.w then x = sf.x + sf.w - s end
    if y + s > sf.y + sf.h then y = sf.y + sf.h - s end
    return { x = x, y = y, w = s, h = s }, screen
  end
  return corner_frame(screen), screen
end

local function save_position(fr, screen)
  local sf = screen:frame()
  config.positions[screen:getUUID()] = {
    x_pct = (fr.x - sf.x) / sf.w,
    y_pct = (fr.y - sf.y) / sf.h,
  }
  save_config()
end

-- ──────────────────────────────────────────────────────────────────
-- viewer html
-- ──────────────────────────────────────────────────────────────────
local function write_viewer_html(state)
  local cb = tostring(hs.timer.absoluteTime())
  local html = string.format([[
<!doctype html>
<html><head><meta charset="utf-8"><style>
  html,body{margin:0;padding:0;width:100%%;height:100%%;
    background:transparent;overflow:hidden;
    -webkit-user-select:none;user-select:none;cursor:grab;}
  img{display:block;width:100vw;height:100vh;object-fit:contain;
      -webkit-user-drag:none;pointer-events:none;}
</style></head>
<body><img src="gifs/%s.gif?%s" alt=""/></body></html>
]], state, cb)
  local f = io.open(VIEWER_HTML, "w")
  if f then f:write(html); f:close() end
end

local function ensure_webview()
  if webview then return end
  local frame = compute_frame()
  webview = hs.webview.new(frame, { developerExtrasEnabled = false })
  webview:windowStyle({ "borderless", "closable" })
  webview:transparent(true)
  webview:allowTextEntry(false)
  webview:allowGestures(false)
  webview:allowMagnificationGestures(false)
  webview:windowTitle("desk-waifu")
  local lvl = (config.level == "popUpMenu")
    and hs.drawing.windowLevels.popUpMenu
    or  hs.drawing.windowLevels.floating
  webview:level(lvl)
  webview:bringToFront(true)
end

local function render(state)
  ensure_webview()
  write_viewer_html(state)
  webview:url("file://" .. VIEWER_HTML)
  if not webview:isVisible() then webview:show() end
end

local function pick_variant(state)
  local pool = VARIANTS[state]
  if not pool or #pool == 0 then return state end
  return pool[math.random(#pool)]
end

-- ──────────────────────────────────────────────────────────────────
-- bubbles (3 channels: user / claude-fact / claude-persona)
-- 设计依据: docs/bubble-tips-prd.md §4 聊天分栏式
--   - user (task)   : 右对齐, 暖色 #6B7AFF α0.7, 14px, 不截断自动撑高
--   - claude (hud)  : 左对齐, 冷色 #2A2A2E α0.5, 13px, 最多 3 行 grapheme 安全截断
--   - glm   (persona): 沿用 claude 槽, 但 ✨ 前缀 + 暖描边, 替换 claude 内容直到 sleep
-- ──────────────────────────────────────────────────────────────────
local function screen_of_point(x, y)
  for _, sc in ipairs(hs.screen.allScreens()) do
    local sf = sc:frame()
    if x >= sf.x and x <= sf.x + sf.w and y >= sf.y and y <= sf.y + sf.h then
      return sc
    end
  end
  return hs.screen.mainScreen()
end

-- 按 grapheme(utf8) 截断, 末尾追加 …。绝不切在多字节中段。
local function ellipsize(text, max_bytes)
  if not text or #text <= max_bytes then return text end
  -- 找到不超过 max_bytes 的最近 utf8 字符边界
  local ok, cut = pcall(utf8.offset, text, -1, max_bytes + 1)
  if not ok or not cut then return text:sub(1, max_bytes) .. "…" end
  return text:sub(1, cut - 1) .. "…"
end

-- 测排版尺寸. style 必须含 font/color/paragraphStyle.
local function measure(text, fs, max_w_inner, alignment)
  local style = {
    font = { name = ".AppleSystemUIFont", size = fs },
    color = { white = 1 },
    paragraphStyle = { alignment = alignment or "left" },
  }
  return hs.drawing.getTextDrawingSize(text, style)
      or { w = #text * fs * 0.6, h = fs * 1.3 }
end

-- forward decls so callbacks can refer to layout 函数
local relayout_bubbles
local hide_user_bubble, hide_claude_bubble, hide_glm_bubble, hide_bubble

-- 单个气泡构造: 返回 canvas, w, h. 不放置 (relayout 负责定位)
local function build_bubble_canvas(opts)
  local pad_x = opts.pad_x or 12
  local pad_y = opts.pad_y or 8
  local fs = opts.font_size
  local max_w = opts.max_w
  local inner_w_cap = max_w - pad_x * 2
  local text = opts.text
  local alignment = opts.alignment or "left"

  local natural = measure(text, fs, inner_w_cap, alignment)
  local line_h = natural.h
  local needed_lines = math.max(1, math.ceil(natural.w / inner_w_cap))
  local lines = opts.max_lines and math.min(opts.max_lines, needed_lines) or needed_lines

  -- 触发截断: 重新测量截短文本
  if opts.max_lines and needed_lines > opts.max_lines then
    -- 估算每行能容纳的字节数 (粗略, utf8 中文按 ~1.5x fs 宽)
    local approx_chars = math.floor(inner_w_cap / (fs * 0.55))
    local budget = approx_chars * opts.max_lines
    text = ellipsize(text, budget * 3)  -- *3 因为中文 utf8 3 字节
  end

  local est_w
  if lines == 1 then
    est_w = math.min(max_w, math.ceil(natural.w) + pad_x * 2)
  else
    est_w = max_w
  end
  local est_h = math.ceil(line_h * lines) + pad_y * 2

  local c = hs.canvas.new({ x = 0, y = 0, w = est_w, h = est_h })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })
  c[#c + 1] = {
    type = "rectangle",
    roundedRectRadii = { xRadius = 12, yRadius = 12 },
    fillColor = opts.fill,
    strokeColor = opts.stroke,
    strokeWidth = opts.stroke_w or 1.0,
  }
  c[#c + 1] = {
    type = "text",
    text = text,
    textColor = opts.text_color,
    textSize = fs,
    textAlignment = alignment,
    frame = { x = pad_x, y = pad_y, w = est_w - pad_x * 2, h = est_h - pad_y * 2 },
  }
  return c, est_w, est_h
end

-- 三个气泡叠放在 waifu 上方. 顺序 (从上到下): user → claude/glm.
-- user 右对齐到 waifu 右边缘, claude 左对齐到 waifu 左边缘. 视觉模拟聊天分栏.
relayout_bubbles = function()
  if not webview then return end
  local wf = webview:frame()
  local screen = screen_of_point(wf.x + wf.w / 2, wf.y + wf.h / 2)
  local sf = screen:frame()
  local gap = 6

  local cl = claude_canvas or glm_canvas  -- 同槽位互斥, glm 优先
  local us = user_canvas

  -- 计算高度从下到上堆叠
  local cur_y = wf.y - gap

  if cl then
    local cf = cl:frame()
    local x = wf.x  -- 左对齐 waifu 左边缘
    if x < sf.x + 4 then x = sf.x + 4 end
    if x + cf.w > sf.x + sf.w - 4 then x = sf.x + sf.w - cf.w - 4 end
    cur_y = cur_y - cf.h
    if cur_y < sf.y + 4 then cur_y = sf.y + 4 end
    cl:topLeft({ x = x, y = cur_y })
    cur_y = cur_y - gap
  end

  if us then
    local uf = us:frame()
    local x = wf.x + wf.w - uf.w  -- 右对齐 waifu 右边缘
    if x < sf.x + 4 then x = sf.x + 4 end
    if x + uf.w > sf.x + sf.w - 4 then x = sf.x + sf.w - uf.w - 4 end
    cur_y = cur_y - uf.h
    if cur_y < sf.y + 4 then cur_y = sf.y + 4 end
    us:topLeft({ x = x, y = cur_y })
  end
end

hide_user_bubble = function()
  if user_canvas then user_canvas:delete(); user_canvas = nil end
end

hide_claude_bubble = function()
  if claude_canvas then claude_canvas:delete(); claude_canvas = nil end
end

hide_glm_bubble = function()
  if glm_canvas then glm_canvas:delete(); glm_canvas = nil end
  glm_text = nil
end

-- 兼容旧调用点 (drag, sleep, stop): 一键清三槽
hide_bubble = function()
  hide_user_bubble()
  hide_claude_bubble()
  hide_glm_bubble()
  if bubble_canvas then bubble_canvas:delete(); bubble_canvas = nil end
  if bubble_timer then bubble_timer:stop(); bubble_timer = nil end
end

local function show_user_bubble(text)
  if not webview then return end
  hide_user_bubble()
  if not text or text == "" then relayout_bubbles(); return end
  local c, _, _ = build_bubble_canvas({
    text        = text,
    font_size   = config.user_font_size or 14,
    max_w       = config.bubble_max_width or 320,
    -- 不设 max_lines: 用户输入永不截断, 自动撑高 (PRD §4.5)
    pad_x = 14, pad_y = 10,
    alignment   = "left",
    fill        = { red = 0.42, green = 0.48, blue = 1.00, alpha = 0.78 },
    stroke      = { red = 0.55, green = 0.62, blue = 1.00, alpha = 0.55 },
    text_color  = { white = 1, alpha = 1 },
  })
  user_canvas = c
  user_canvas:show()
  relayout_bubbles()
end

local function show_claude_bubble(text)
  if not webview then return end
  hide_glm_bubble()  -- 新事实进来时让位 glm
  hide_claude_bubble()
  if not text or text == "" then relayout_bubbles(); return end
  local c, _, _ = build_bubble_canvas({
    text        = text,
    font_size   = config.claude_font_size or 13,
    max_w       = math.floor((config.bubble_max_width or 320) * 0.92),
    max_lines   = 3,
    pad_x = 12, pad_y = 8,
    alignment   = "left",
    fill        = { red = 0.16, green = 0.17, blue = 0.19, alpha = 0.78 },
    stroke      = { red = 0.50, green = 0.50, blue = 0.55, alpha = 0.45 },
    text_color  = { red = 0.82, green = 0.82, blue = 0.85, alpha = 1 },
  })
  claude_canvas = c
  claude_canvas:show()
  relayout_bubbles()
end

local function show_glm_bubble(text)
  if not webview then return end
  hide_claude_bubble()  -- 同槽
  hide_glm_bubble()
  if not text or text == "" then relayout_bubbles(); return end
  glm_text = text
  local c, _, _ = build_bubble_canvas({
    text        = "✨ " .. text,
    font_size   = config.claude_font_size or 13,
    max_w       = math.floor((config.bubble_max_width or 320) * 0.92),
    max_lines   = 3,
    pad_x = 12, pad_y = 8,
    alignment   = "left",
    fill        = { red = 0.16, green = 0.17, blue = 0.19, alpha = 0.88 },
    stroke      = { red = 0.95, green = 0.78, blue = 0.55, alpha = 0.75 },
    text_color  = { red = 0.98, green = 0.93, blue = 0.80, alpha = 1 },
    stroke_w    = 1.2,
  })
  glm_canvas = c
  glm_canvas:show()
  relayout_bubbles()
end

local function render_hud_now(text)
  -- sticky 哨兵: 前导 \1 (SOH) = 不自动 fade (PRD §4.7, Notification/PermissionRequest).
  local sticky = false
  if text and text:sub(1, 1) == "\1" then
    sticky = true
    text = text:sub(2)
  end
  hud_text = text
  last_hud_shown_at = hs.timer.secondsSinceEpoch()
  show_claude_bubble(text)
  if hud_fade_timer then hud_fade_timer:stop(); hud_fade_timer = nil end
  if not sticky then
    hud_fade_timer = hs.timer.doAfter(config.hud_hold_max or 8, function()
      hud_text = nil
      if claude_canvas then hide_claude_bubble(); relayout_bubbles() end
    end)
  end
end

local function on_task_change()
  local raw = read_file(TASK_FILE)
  if not raw or raw == "" then
    task_text = nil
    hide_user_bubble(); relayout_bubbles()
    return
  end
  local ts, text = raw:match("^(%d+)\t(.-)\n?$")
  if not ts then text = raw:gsub("[\r\n]+$", "") end
  local ts_num = tonumber(ts or "") or 0
  if ts_num > 0 and ts_num <= last_task_ts then return end
  last_task_ts = ts_num
  task_text = (text and text ~= "") and text or nil
  if task_text then
    -- 新一轮开始: 清掉上一轮残留的 claude 气泡 + sticky alert (PRD §4.7).
    if hud_fade_timer then hud_fade_timer:stop(); hud_fade_timer = nil end
    hud_text = nil
    hide_claude_bubble()
    show_user_bubble(task_text)
  else
    hide_user_bubble(); relayout_bubbles()
  end
end

local function on_hud_change()
  local raw = read_file(HUD_FILE); if not raw or raw == "" then return end
  local ts, text = raw:match("^(%d+)\t(.-)\n?$")
  if not ts then text = raw:gsub("[\r\n]+$", "") end
  local ts_num = tonumber(ts or "") or 0
  if ts_num <= last_hud_ts then return end
  last_hud_ts = ts_num
  if not text or text == "" then return end

  -- 节流: 上条 HUD 还没显示满 min_show 秒, 就缓存到 pending, 等到点再 flush
  local now = hs.timer.secondsSinceEpoch()
  local min_show = config.hud_min_show or 0.8
  local elapsed = now - last_hud_shown_at
  if claude_canvas and elapsed < min_show then
    pending_hud_text = text
    if not pending_hud_timer then
      pending_hud_timer = hs.timer.doAfter(min_show - elapsed, function()
        pending_hud_timer = nil
        local t = pending_hud_text; pending_hud_text = nil
        if t then render_hud_now(t) end
      end)
    end
    return
  end
  render_hud_now(text)
end

-- 状态机切换时短显的本地静态台词. 路由到 claude 槽以保持单一布局.
local function show_static_line(state)
  if not webview then return end
  if glm_canvas then return end  -- glm 在场让位
  local pool = (config.state_lines and config.state_lines[state]) or STATE_LINES[state]
  if not pool or #pool == 0 then return end
  local text = pool[math.random(#pool)]
  show_claude_bubble(text)
  if bubble_timer then bubble_timer:stop() end
  bubble_timer = hs.timer.doAfter(config.static_line_hold or 5, function()
    if claude_canvas then hide_claude_bubble(); relayout_bubbles() end
  end)
end

-- ── thinking 小气泡（GLM 调用 in-flight 时显示） ─────────────────
local function hide_thinking()
  if thinking_anim_timer then thinking_anim_timer:stop(); thinking_anim_timer = nil end
  if thinking_canvas then thinking_canvas:delete(); thinking_canvas = nil end
end

local function show_thinking()
  if not webview then return end
  hide_thinking()
  local wf = webview:frame()
  local w, h = 56, 28
  local screen = screen_of_point(wf.x + wf.w / 2, wf.y + wf.h / 2)
  local sf = screen:frame()
  local x = wf.x + (wf.w - w) / 2
  local y = wf.y - h - 4
  if y < sf.y + 4 then y = wf.y + wf.h + 4 end
  thinking_canvas = hs.canvas.new({ x = x, y = y, w = w, h = h })
  thinking_canvas:level(hs.canvas.windowLevels.overlay)
  thinking_canvas:behavior({ "canJoinAllSpaces", "stationary" })
  thinking_canvas[#thinking_canvas + 1] = {
    type = "rectangle",
    roundedRectRadii = { xRadius = 14, yRadius = 14 },
    fillColor = { red = 0.10, green = 0.12, blue = 0.14, alpha = 0.88 },
    strokeColor = { red = 0.95, green = 0.78, blue = 0.55, alpha = 0.75 },
    strokeWidth = 1,
  }
  -- 三个圆点，用 alpha 帧动画模拟"打字中"
  for i = 1, 3 do
    thinking_canvas[#thinking_canvas + 1] = {
      type = "circle",
      center = { x = 14 + (i - 1) * 14, y = h / 2 },
      radius = 3,
      fillColor = { red = 0.98, green = 0.93, blue = 0.80, alpha = 0.35 },
      action = "fill",
    }
  end
  thinking_canvas:show()
  local phase = 0
  thinking_anim_timer = hs.timer.doEvery(0.35, function()
    if not thinking_canvas then return end
    phase = (phase % 3) + 1
    for i = 1, 3 do
      thinking_canvas[1 + i].fillColor.alpha = (i == phase) and 1.0 or 0.35
    end
  end)
end

local function on_thinking_change()
  local raw = read_file(THINK_FILE)
  local active = raw and raw:gsub("%s+", "") ~= "" or false
  if active then show_thinking() else hide_thinking() end
end

local function on_bubble_change()
  local raw = read_file(BUBBLE_FILE); if not raw or raw == "" then return end
  local ts, text = raw:match("^(%d+)\t(.-)\n?$")
  if not ts then text = raw:gsub("[\r\n]+$", "") end
  local ts_num = tonumber(ts or "") or hs.timer.secondsSinceEpoch()
  if ts_num <= last_bubble_ts then return end
  last_bubble_ts = ts_num
  hide_thinking()  -- 真台词到了, 吞掉 thinking 点点
  if text and text ~= "" then
    show_glm_bubble(text)
    if bubble_timer then bubble_timer:stop(); bubble_timer = nil end
  end
end

-- ──────────────────────────────────────────────────────────────────
-- state machine
-- ──────────────────────────────────────────────────────────────────
local function schedule_revert()
  if revert_timer then revert_timer:stop(); revert_timer = nil end
  revert_timer = hs.timer.doAfter(config.celebrate_hold or 60, function()
    revert_timer = nil
    local f = io.open(STATE_FILE, "w")
    if f then f:write("sleep\n"); f:close() end
  end)
end

local function on_state_change()
  local raw = read_file(STATE_FILE); if not raw then return end
  local state = raw:gsub("%s+$", ""):gsub("^%s+", "")
  if state == "" then return end
  if not VARIANTS[state] and state == current_state then return end

  local visual = pick_variant(state)
  if not file_exists(GIFS_DIR .. "/" .. visual .. ".gif") then
    print(string.format("[desk-waifu] no gif for '%s'", state)); return
  end

  if state ~= "celebrate" and revert_timer then
    revert_timer:stop(); revert_timer = nil
  end

  local prev_state = current_state
  current_state = state
  last_event_at = hs.timer.secondsSinceEpoch()
  render(visual)
  -- 进入 sleep 时清空气泡：状态条已无承诺，留着是噪音
  if state == "sleep" then hide_bubble(); hide_thinking() end
  if state == "celebrate" then schedule_revert() end

  -- 注：静态池已下岗。HUD 通道（hud-writer.sh → /hud 文件）每个事件都会
  -- 写一行事实，频率比状态切换更密、信息量更高。
  -- 如果你想要回静态吐槽，把下面那行解注释；保留时机判断避免覆盖 GLM。
  -- if state ~= prev_state and state ~= "sleep" and state ~= "celebrate" then
  --   show_static_line(state)
  -- end
  if state == prev_state then return end  -- noop branch
end

local function check_idle()
  if not current_state or current_state == "sleep" or current_state == "celebrate" then return end
  if hs.timer.secondsSinceEpoch() - last_event_at >= (config.idle_threshold or 180) then
    local f = io.open(STATE_FILE, "w")
    if f then f:write("sleep\n"); f:close() end
  end
end

local function on_path_event(paths)
  for _, p in ipairs(paths or {}) do
    if     p:match("/state$")    then on_state_change()
    elseif p:match("/bubble$")   then on_bubble_change()
    elseif p:match("/hud$")      then on_hud_change()
    elseif p:match("/task$")     then on_task_change()
    elseif p:match("/thinking$") then on_thinking_change()
    end
  end
end

-- ──────────────────────────────────────────────────────────────────
-- drag
-- ──────────────────────────────────────────────────────────────────
local function point_in_frame(p, fr)
  return p.x >= fr.x and p.x <= fr.x + fr.w
     and p.y >= fr.y and p.y <= fr.y + fr.h
end

-- 触控板友好的拖动：按住 ⌥(option) 在 waifu 上移动指针即拖；松开 ⌥ 自动保存。
-- 鼠标按住拖（leftMouseDragged）仍然能用，自动二选一。
--
-- 性能要点：
-- - light_tap 常驻，只订阅 leftMouseDown / flagsChanged（低频）
-- - drag_tap 仅拖动期 :start()/:stop()，订阅 mouseMoved / leftMouseDragged / leftMouseUp
-- - move_to 节流到 ~90Hz，并缓存 webview:hswindow() 避免每帧 ObjC 桥调用

local function move_to(nx, ny)
  if not webview then return end
  local now = hs.timer.secondsSinceEpoch()
  if now - last_move_at < MOVE_MIN_DT then return end
  last_move_at = now
  cached_hw = cached_hw or (webview.hswindow and webview:hswindow())
  if cached_hw then
    cached_hw:setTopLeft({ x = nx, y = ny })
  else
    local wf = webview:frame()
    webview:frame({ x = nx, y = ny, w = wf.w, h = wf.h })
  end
end

local function stop_drag_tap()
  if drag_tap and drag_tap:isEnabled() then drag_tap:stop() end
end

local function finalize_drag()
  if not drag then return end
  drag = nil
  stop_drag_tap()
  if not webview then return end
  local fr = webview:frame()
  local mx, my = fr.x + fr.w / 2, fr.y + fr.h / 2
  local screen = pick_screen()
  for _, sc in ipairs(hs.screen.allScreens()) do
    local sf = sc:frame()
    if mx >= sf.x and mx <= sf.x + sf.w
       and my >= sf.y and my <= sf.y + sf.h then
      screen = sc; break
    end
  end
  save_position(fr, screen)
  current_screen_uuid = screen:getUUID()
  -- 拖动结束: 把仍然在 state 中的气泡重新画回新位置
  if task_text  then show_user_bubble(task_text)   end
  if glm_text   then show_glm_bubble(glm_text)
  elseif hud_text then show_claude_bubble(hud_text) end
end

local function ensure_drag_tap()
  if drag_tap then return end
  local et = hs.eventtap.event.types
  drag_tap = hs.eventtap.new(
    { et.mouseMoved, et.leftMouseDragged, et.leftMouseUp },
    function(ev)
      if not drag or not webview then return false end
      local t = ev:getType()
      local p = hs.mouse.absolutePosition()
      if t == et.mouseMoved then
        if drag.mode == "opt" then move_to(p.x - drag.dx, p.y - drag.dy) end
        return false
      end
      if t == et.leftMouseDragged then
        if drag.mode == "btn" then
          move_to(p.x - drag.dx, p.y - drag.dy)
          return true
        end
        return false
      end
      if t == et.leftMouseUp then
        if drag.mode == "btn" then finalize_drag(); return true end
        return false
      end
      return false
    end)
end

local function begin_drag(mode, p, wf)
  drag = { dx = p.x - wf.x, dy = p.y - wf.y, mode = mode, start_wf = wf }
  -- 拖动期暂时藏起所有气泡, finalize_drag 后由 task/hud 状态自然恢复
  hide_bubble()
  cached_hw = nil  -- 拖动开始重新拿一次 hswindow, 避免 reload 后引用旧句柄
  ensure_drag_tap()
  if drag_tap and not drag_tap:isEnabled() then drag_tap:start() end
end

local function start_light_tap()
  if light_tap then return end
  local et = hs.eventtap.event.types
  light_tap = hs.eventtap.new(
    { et.leftMouseDown, et.flagsChanged },
    function(ev)
      if not webview or not webview:isVisible() then return false end
      local t = ev:getType()
      local p = hs.mouse.absolutePosition()
      local wf = webview:frame()

      if t == et.flagsChanged then
        local flags = ev:getFlags()
        local opt_down = flags and flags.alt
        if opt_down and not drag and point_in_frame(p, wf) then
          begin_drag("opt", p, wf)
        elseif not opt_down and drag and drag.mode == "opt" then
          finalize_drag()
        end
        return false
      end

      if t == et.leftMouseDown then
        if point_in_frame(p, wf) and not drag then
          begin_drag("btn", p, wf)
          return true
        end
      end
      return false
    end)
  light_tap:start()
end

-- ──────────────────────────────────────────────────────────────────
-- public api
-- ──────────────────────────────────────────────────────────────────
function M.toggle()
  if not webview then return end
  if webview:isVisible() then webview:hide(); hide_bubble() else webview:show() end
end

function M.cycle_corner()
  local order = { "bottom-right", "bottom-left", "top-left", "top-right" }
  for i, c in ipairs(order) do
    if c == config.corner then config.corner = order[(i % #order) + 1]; break end
  end
  -- 清除当前屏幕的保存位置，回到 corner 预设
  local screen = pick_screen()
  config.positions[screen:getUUID()] = nil
  save_config()
  if webview then
    local fr = corner_frame(screen)
    webview:frame(fr)
  end
end

function M.reload() M.stop(); M.start() end

function M.reposition()
  if not webview then return end
  local fr, screen = compute_frame()
  webview:frame(fr)
  current_screen_uuid = screen:getUUID()
  relayout_bubbles()
end

function M.start()
  load_config()
  math.randomseed(os.time())
  os.execute(string.format("mkdir -p %q %q", DATA_DIR, GIFS_DIR))
  if not file_exists(STATE_FILE) then
    local f = io.open(STATE_FILE, "w"); if f then f:write("sleep\n"); f:close() end
  end
  current_state = nil
  on_state_change()
  if not current_state then render("sleep"); current_state = "sleep" end

  state_watcher = hs.pathwatcher.new(DATA_DIR .. "/", on_path_event):start()
  variant_timer = hs.timer.doEvery(config.variant_period or 12, function()
    if current_state and VARIANTS[current_state] then render(pick_variant(current_state)) end
  end)
  idle_timer = hs.timer.doEvery(config.idle_check or 30, check_idle)

  -- 主动台词决策器：后台跑 speech-tick.sh，自带触发条件 + 限速。
  if file_exists(SPEECH_TICK) then
    speech_timer = hs.timer.doEvery(config.speech_tick_period or 300, function()
      hs.task.new(SPEECH_TICK, nil, {}):start()
    end)
  end

  -- 显示器插拔 / 主屏切换时重定位
  screen_watcher = hs.screen.watcher.new(M.reposition):start()

  start_light_tap()

  hs.hotkey.bind(config.hotkey_toggle.mods, config.hotkey_toggle.key, M.toggle)
  hs.hotkey.bind(config.hotkey_cycle.mods,  config.hotkey_cycle.key,  M.cycle_corner)
  hs.hotkey.bind(config.hotkey_reload.mods, config.hotkey_reload.key, M.reload)

  -- 启动时拉一次 bubble / task（拾取上次遗留的 pin）
  on_bubble_change()
  on_task_change()

  print("[desk-waifu] started, state=" .. tostring(current_state))
end

function M.stop()
  if state_watcher  then state_watcher:stop();  state_watcher  = nil end
  if screen_watcher then screen_watcher:stop(); screen_watcher = nil end
  if drag_tap       then drag_tap:stop();       drag_tap       = nil end
  if light_tap      then light_tap:stop();      light_tap      = nil end
  cached_hw = nil; drag = nil; last_move_at = 0
  if revert_timer   then revert_timer:stop();   revert_timer   = nil end
  if variant_timer  then variant_timer:stop();  variant_timer  = nil end
  if idle_timer     then idle_timer:stop();     idle_timer     = nil end
  if speech_timer   then speech_timer:stop();   speech_timer   = nil end
  if pending_hud_timer then pending_hud_timer:stop(); pending_hud_timer = nil end
  if hud_fade_timer    then hud_fade_timer:stop();    hud_fade_timer    = nil end
  pending_hud_text = nil
  task_text = nil; hud_text = nil
  hide_thinking()
  hide_bubble()
  if webview then webview:delete(); webview = nil end
  current_state = nil
end

M.start()
return M
