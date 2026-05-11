-- desk-waifu — chibi 桌面伴侣，受 ~/.desk-waifu/state 与 ~/.desk-waifu/bubble 驱动
-- 安装位置: ~/.hammerspoon/desk-waifu.lua
-- 在 ~/.hammerspoon/init.lua 末尾追加: require('desk-waifu')

local M = {}

local DATA_DIR     = os.getenv("HOME") .. "/.desk-waifu"
local STATE_FILE   = DATA_DIR .. "/state"
local BUBBLE_FILE  = DATA_DIR .. "/bubble"
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
  positions       = {},             -- { [screen_uuid] = { x_pct=, y_pct= } }
  hotkey_toggle   = { mods = {"cmd","alt"}, key = "p" },
  hotkey_cycle    = { mods = {"cmd","alt"}, key = ";" },
  hotkey_reload   = { mods = {"cmd","alt"}, key = "r" },
}

local VARIANTS = { coding = { "coding", "fix_bug" } }

local config = {}
local webview, bubble_canvas
local state_watcher, screen_watcher, drag_tap
local current_state, current_screen_uuid
local revert_timer, variant_timer, idle_timer, bubble_timer, speech_timer
local thinking_canvas, thinking_anim_timer
local last_event_at, last_bubble_ts = 0, 0
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
-- bubble
-- ──────────────────────────────────────────────────────────────────
local function hide_bubble()
  if bubble_canvas then bubble_canvas:delete(); bubble_canvas = nil end
  if bubble_timer then bubble_timer:stop(); bubble_timer = nil end
end

local function screen_of_point(x, y)
  for _, sc in ipairs(hs.screen.allScreens()) do
    local sf = sc:frame()
    if x >= sf.x and x <= sf.x + sf.w and y >= sf.y and y <= sf.y + sf.h then
      return sc
    end
  end
  return hs.screen.mainScreen()
end

local function show_bubble(text)
  if not webview then return end
  hide_bubble()
  local wf = webview:frame()
  local pad_x, pad_y = 12, 8
  local fs = config.bubble_font_size or 14
  local max_w = config.bubble_max_width or 320
  local max_lines = config.bubble_max_lines or 3
  local inner_w_cap = max_w - pad_x * 2

  -- 用系统真实排版测字号尺寸，避免估算偏差
  local style = {
    font = { name = ".AppleSystemUIFont", size = fs },
    color = { white = 1 },
    paragraphStyle = { alignment = "center" },
  }
  local natural = hs.drawing.getTextDrawingSize(text, style) or { w = #text * fs, h = fs * 1.3 }
  local line_h = natural.h
  local lines = math.min(max_lines, math.max(1, math.ceil(natural.w / inner_w_cap)))
  local est_w
  if lines == 1 then
    est_w = math.min(max_w, math.ceil(natural.w) + pad_x * 2)
  else
    est_w = max_w
  end
  local est_h = math.ceil(line_h * lines) + pad_y * 2

  -- 关键：用 waifu 中心点判屏，不要用鼠标所在屏。双屏下鼠标可能在另一块屏。
  local screen = screen_of_point(wf.x + wf.w / 2, wf.y + wf.h / 2)
  local sf = screen:frame()
  local x = wf.x + (wf.w - est_w) / 2
  local y = wf.y - est_h - 6
  if y < sf.y + 4 then y = wf.y + wf.h + 6 end
  if x < sf.x + 4 then x = sf.x + 4 end
  if x + est_w > sf.x + sf.w - 4 then x = sf.x + sf.w - est_w - 4 end

  bubble_canvas = hs.canvas.new({ x = x, y = y, w = est_w, h = est_h })
  bubble_canvas:level(hs.canvas.windowLevels.overlay)
  bubble_canvas:behavior({ "canJoinAllSpaces", "stationary" })
  bubble_canvas[#bubble_canvas + 1] = {
    type = "rectangle",
    roundedRectRadii = { xRadius = 10, yRadius = 10 },
    fillColor = { red = 0.10, green = 0.12, blue = 0.14, alpha = 0.92 },
    strokeColor = { red = 0.95, green = 0.78, blue = 0.55, alpha = 0.85 },
    strokeWidth = 1.2,
  }
  bubble_canvas[#bubble_canvas + 1] = {
    type = "text",
    text = text,
    textColor = { red = 0.98, green = 0.93, blue = 0.80, alpha = 1 },
    textSize = fs,
    textAlignment = "center",
    frame = { x = pad_x, y = pad_y, w = est_w - pad_x * 2, h = est_h - pad_y * 2 },
  }
  bubble_canvas:show()

  -- sticky 模式：bubble_hold <= 0 时不自动隐藏，由下一条台词或 sleep 状态清除
  local hold = config.bubble_hold or 0
  if hold > 0 then
    bubble_timer = hs.timer.doAfter(hold, hide_bubble)
  end
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
  hide_thinking()  -- 真台词到了，吞掉 thinking 点点
  if text and text ~= "" then show_bubble(text) end
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

  current_state = state
  last_event_at = hs.timer.secondsSinceEpoch()
  render(visual)
  -- 进入 sleep 时清空气泡：状态条已无承诺，留着是噪音
  if state == "sleep" then hide_bubble(); hide_thinking() end
  if state == "celebrate" then schedule_revert() end
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
-- 同时保留鼠标按住拖（leftMouseDragged）作为有鼠标场景下的快捷路径。
local function move_to(nx, ny)
  if not webview then return end
  local hw = webview.hswindow and webview:hswindow()
  if hw then
    hw:setTopLeft({ x = nx, y = ny })
  else
    local wf = webview:frame()
    webview:frame({ x = nx, y = ny, w = wf.w, h = wf.h })
  end
end

local function finalize_drag()
  if not drag then return end
  drag = nil
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
end

local function start_drag_tap()
  if drag_tap then return end
  local et = hs.eventtap.event.types
  drag_tap = hs.eventtap.new(
    { et.leftMouseDown, et.leftMouseDragged, et.leftMouseUp,
      et.mouseMoved, et.flagsChanged },
    function(ev)
      if not webview or not webview:isVisible() then return false end
      local t = ev:getType()
      local p = hs.mouse.absolutePosition()
      local wf = webview:frame()
      local flags = ev:getFlags()
      local opt_down = flags and flags.alt

      -- option modifier path（触控板首选）
      if t == et.flagsChanged then
        if opt_down and not drag and point_in_frame(p, wf) then
          drag = { dx = p.x - wf.x, dy = p.y - wf.y, mode = "opt" }
          if bubble_canvas then hide_bubble() end
        elseif not opt_down and drag and drag.mode == "opt" then
          finalize_drag()
        end
        return false
      end

      if t == et.mouseMoved then
        if drag and drag.mode == "opt" then
          move_to(p.x - drag.dx, p.y - drag.dy)
        end
        return false
      end

      -- 鼠标按住拖动路径（有外接鼠标时仍然能用）
      if t == et.leftMouseDown then
        if point_in_frame(p, wf) and not drag then
          drag = { dx = p.x - wf.x, dy = p.y - wf.y, mode = "btn" }
          if bubble_canvas then hide_bubble() end
          return true
        end
      elseif t == et.leftMouseDragged then
        if drag and drag.mode == "btn" then
          move_to(p.x - drag.dx, p.y - drag.dy)
          return true
        end
      elseif t == et.leftMouseUp then
        if drag and drag.mode == "btn" then
          finalize_drag()
          return true
        end
      end
      return false
    end)
  drag_tap:start()
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

  start_drag_tap()

  hs.hotkey.bind(config.hotkey_toggle.mods, config.hotkey_toggle.key, M.toggle)
  hs.hotkey.bind(config.hotkey_cycle.mods,  config.hotkey_cycle.key,  M.cycle_corner)
  hs.hotkey.bind(config.hotkey_reload.mods, config.hotkey_reload.key, M.reload)

  -- 启动时拉一次 bubble（如果有遗留）
  on_bubble_change()

  print("[desk-waifu] started, state=" .. tostring(current_state))
end

function M.stop()
  if state_watcher  then state_watcher:stop();  state_watcher  = nil end
  if screen_watcher then screen_watcher:stop(); screen_watcher = nil end
  if drag_tap       then drag_tap:stop();       drag_tap       = nil end
  if revert_timer   then revert_timer:stop();   revert_timer   = nil end
  if variant_timer  then variant_timer:stop();  variant_timer  = nil end
  if idle_timer     then idle_timer:stop();     idle_timer     = nil end
  if speech_timer   then speech_timer:stop();   speech_timer   = nil end
  hide_thinking()
  hide_bubble()
  if webview then webview:delete(); webview = nil end
  current_state = nil
end

M.start()
return M
