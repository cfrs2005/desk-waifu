-- desk-waifu — chibi 桌面伴侣，受 ~/.desk-waifu/state 文件驱动
-- 安装位置: ~/.hammerspoon/desk-waifu.lua
-- 在 ~/.hammerspoon/init.lua 末尾追加: require('desk-waifu')

local M = {}

local DATA_DIR    = os.getenv("HOME") .. "/.desk-waifu"
local STATE_FILE  = DATA_DIR .. "/state"
local GIFS_DIR    = DATA_DIR .. "/gifs"
local CONFIG_FILE = DATA_DIR .. "/config.json"
local VIEWER_HTML = DATA_DIR .. "/viewer.html"

local DEFAULTS = {
  size           = 240,
  margin         = 20,
  corner         = "bottom-right", -- bottom-right | bottom-left | top-right | top-left
  level          = "floating",     -- floating | popUpMenu
  hotkey_toggle  = { mods = {"cmd","alt"}, key = "p" },
  hotkey_cycle   = { mods = {"cmd","alt"}, key = ";" },
  hotkey_reload  = { mods = {"cmd","alt"}, key = "r" },
}

local config = {}
local webview = nil
local watcher = nil
local current_state = nil

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

local function file_exists(path)
  local f = io.open(path, "r"); if f then f:close(); return true end; return false
end

local function load_config()
  config = {}
  for k, v in pairs(DEFAULTS) do config[k] = v end
  local raw = read_file(CONFIG_FILE)
  if raw and raw ~= "" then
    local ok, data = pcall(hs.json.decode, raw)
    if ok and type(data) == "table" then
      for k, v in pairs(data) do config[k] = v end
    end
  end
end

local function compute_frame()
  local sf = hs.screen.mainScreen():frame()
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

local function write_viewer_html(state)
  -- gif is loaded via a relative path so the document and the image share the
  -- same file:// origin, sidestepping WKWebView's same-origin restrictions on
  -- :html(string, baseURL).
  local cb = tostring(hs.timer.absoluteTime())
  local html = string.format([[
<!doctype html>
<html><head><meta charset="utf-8"><style>
  html,body{margin:0;padding:0;width:100%%;height:100%%;
    background:transparent;overflow:hidden;
    -webkit-user-select:none;user-select:none;cursor:default;}
  img{display:block;width:100vw;height:100vh;object-fit:contain;}
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

local function on_state_change()
  local raw = read_file(STATE_FILE); if not raw then return end
  local state = raw:gsub("%s+$", ""):gsub("^%s+", "")
  if state == "" or state == current_state then return end
  if not file_exists(GIFS_DIR .. "/" .. state .. ".gif") then
    print(string.format("[desk-waifu] no gif for state '%s', ignored", state))
    return
  end
  current_state = state
  render(state)
end

local function on_path_event(paths)
  for _, p in ipairs(paths or {}) do
    if p:match("/state$") then on_state_change(); return end
  end
end

function M.toggle()
  if not webview then return end
  if webview:isVisible() then webview:hide() else webview:show() end
end

function M.cycle_corner()
  local order = { "bottom-right", "bottom-left", "top-left", "top-right" }
  for i, c in ipairs(order) do
    if c == config.corner then
      config.corner = order[(i % #order) + 1]; break
    end
  end
  if webview then webview:frame(compute_frame()) end
end

function M.reload()
  M.stop(); M.start()
end

function M.start()
  load_config()
  os.execute(string.format("mkdir -p %q %q", DATA_DIR, GIFS_DIR))
  if not file_exists(STATE_FILE) then
    local f = io.open(STATE_FILE, "w")
    if f then f:write("idle_blink\n"); f:close() end
  end
  current_state = nil
  on_state_change()
  if not current_state then render("idle_blink"); current_state = "idle_blink" end
  watcher = hs.pathwatcher.new(DATA_DIR .. "/", on_path_event):start()
  hs.hotkey.bind(config.hotkey_toggle.mods, config.hotkey_toggle.key, M.toggle)
  hs.hotkey.bind(config.hotkey_cycle.mods,  config.hotkey_cycle.key,  M.cycle_corner)
  hs.hotkey.bind(config.hotkey_reload.mods, config.hotkey_reload.key, M.reload)
  print("[desk-waifu] started, state=" .. tostring(current_state))
end

function M.stop()
  if watcher then watcher:stop(); watcher = nil end
  if webview then webview:delete(); webview = nil end
  current_state = nil
end

M.start()
return M
