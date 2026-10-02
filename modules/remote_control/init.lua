-- Remote control mapping and management engine for Hammerspoon.
-- Supports Xiaomi Bluetooth Remote 2 Pro and other Bluetooth/USB remotes.
-- Features:
--   - Device isolation via macOS hidutil
--   - Tap / Hold / Double-click state machine
--   - Per-App profiles (Terminal/Termux, Web Browser, Global)
--   - Native integration with VoiceInput (streaming Doubao ASR)
--   - Native integration with WindowSwitcher (vertical Alt-Tab)
--   - Persistent Control Panel (Dashboard) via hs.webview

local M = {}
local InputTarget = require("modules.input_target")

local log = hs.logger.new("remote-ctrl", "debug")
local configDir = hs.configdir or ((os.getenv("HOME") or "") .. "/.hammerspoon")
local moduleDir = (function()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    return src:sub(2):match("(.*/)")
  end
  return configDir .. "/modules/remote_control/"
end)() or (configDir .. "/modules/remote_control/")

local function resolveFile(relName, legacyRootName)
  local localPath = moduleDir .. relName
  if hs.fs.attributes(localPath, "mode") == "file" then
    return localPath
  end
  if legacyRootName then
    local rootPath = configDir .. "/" .. legacyRootName
    if hs.fs.attributes(rootPath, "mode") == "file" then
      return rootPath
    end
  end
  return localPath
end

local CONFIG_FILE = resolveFile("config.json", "remote_config.json")
local EXAMPLE_FILE = resolveFile("config.json.example", "remote_config.json.example")
local DASHBOARD_HTML = resolveFile("dashboard.html", "remote_dashboard.html")
local DEBUG_LOG = moduleDir .. "debug.log"

local function logToFile(fmt, ...)
  local msg = string.format(fmt, ...)
  local ts = os.date("%Y-%m-%d %H:%M:%S")
  local f = io.open(DEBUG_LOG, "a")
  if f then
    f:write(string.format("[%s] %s\n", ts, msg))
    f:close()
  end
  log.d(msg)
end

-- Default transit key mappings (Virtual F13-F24 exclusively mapped from remote via hidutil/IOHID)
-- Standard keyboard keys (F1-F12) MUST NEVER be placed here to prevent hijacking user keyboard!
local HIDUTIL_MAPPINGS = {
  { src = 0x700000052, dst = 0x700000068, keycode = 105, key = "up" },
  { src = 0x700000051, dst = 0x700000069, keycode = 107, key = "down" },
  { src = 0x700000050, dst = 0x70000006A, keycode = 113, key = "left" },
  { src = 0x70000004F, dst = 0x70000006B, keycode = 106, key = "right" },
  { src = 0x700000028, dst = 0x70000006C, keycode = 64,  key = "ok" },
  { src = 0x70000003E, dst = 0x70000006D, keycode = 79,  key = "voice" },
  { src = 0x700000065, dst = 0x70000006F, keycode = 90,  key = "menu" },
  { src = 0x700000035, dst = 0x700000070, keycode = 144, key = "tv" },
  { src = 0x700000080, dst = 0x700000071, keycode = 145, key = "volume_up" },
  { src = 0xC000000E9, dst = 0x700000071, keycode = 145, key = "volume_up" },
  { src = 0x700000081, dst = 0x700000072, keycode = 146, key = "volume_down" },
  { src = 0xC000000EA, dst = 0x700000072, keycode = 146, key = "volume_down" },
  { src = 0x70000004A, dst = 0x70000006E, keycode = 80,  key = "home" },
  { src = 0xC00000223, dst = 0x70000006E, keycode = 80,  key = "home" },
  { src = 0x700000066, dst = 0x700000073, keycode = 147, key = "power" },
  { src = 0xC00000030, dst = 0x700000073, keycode = 147, key = "power" },
  { src = 0xC00000224, dst = 0x70000006E, keycode = 80,  key = "back", isolationOnly = true },
}
-- IOHID supplies button identity. The OS only needs one inert transit key;
-- F14/F15 can be translated into display-brightness events before keyDown taps.
local ISOLATION_KEYCODE = 90 -- F20
for _, row in ipairs(HIDUTIL_MAPPINGS) do
  row.dst = 0x70000006F
  row.keycode = ISOLATION_KEYCODE
  row.isolationOnly = true
end
-- Some remotes emit consumer brightness events alongside keyboard events.
for _, usage in ipairs({ 0x6F, 0x70 }) do
  HIDUTIL_MAPPINGS[#HIDUTIL_MAPPINGS + 1] = {
    src = 0xC00000000 + usage, dst = 0x70000006F,
    keycode = ISOLATION_KEYCODE, key = "brightness", isolationOnly = true,
  }
end
M.HIDUTIL_MAPPINGS = HIDUTIL_MAPPINGS

local TRANSIT_KEY_MAP = {}

local function hidutilUserKeyMapping()
  local mappings = {}
  for _, row in ipairs(HIDUTIL_MAPPINGS) do
    mappings[#mappings + 1] = {
      HIDKeyboardModifierMappingSrc = row.src,
      HIDKeyboardModifierMappingDst = row.dst,
    }
  end
  return mappings
end

local function rebuildTransitKeyMap()
  local map = { [ISOLATION_KEYCODE] = "isolated_remote" }
  TRANSIT_KEY_MAP = map
  M.TRANSIT_KEY_MAP = map
end
M.rebuildTransitKeyMap = rebuildTransitKeyMap
rebuildTransitKeyMap()

M._hidutilApplyPayload = function()
  return hs.json.encode({ UserKeyMapping = hidutilUserKeyMapping() })
end

local DEFAULT_TERMINAL_BUNDLES = {
  ["com.mitchellh.ghostty"] = true,
  ["com.googlecode.iterm2"] = true,
  ["com.apple.Terminal"] = true,
  ["io.alacritty"] = true,
  ["net.kovidgoyal.kitty"] = true,
  ["com.github.wez.wezterm"] = true,
  ["dev.warp.Warp-GDK"] = true,
}

local DEFAULT_BROWSER_BUNDLES = {
  ["com.google.Chrome"] = true,
  ["company.thebrowser.Arc"] = true,
  ["com.apple.Safari"] = true,
  ["org.mozilla.firefox"] = true,
  ["com.microsoft.edgemac"] = true,
  ["com.brave.Browser"] = true,
}

local state = {
  config = nil,
  eventtap = nil,
  hidTask = nil,
  connectedDeviceCount = 0,
  dashboard = nil,
  dashboardUserContent = nil,
  isDashboardVisible = false,
  mouseMode = false,
  mouseTimer = nil,
  mouseHeldKey = nil,
  _testBundleID = nil,
  terminalBundles = DEFAULT_TERMINAL_BUNDLES,
  browserBundles = DEFAULT_BROWSER_BUNDLES,
  activeKeys = {},
  keyTimers = {},
  doubleTapTimers = {},
  pendingDoubleTap = {},
  pressContexts = {},
  repeatTimers = {},
  navigationEpoch = 0,
  inputEpoch = 0,
  reviewMode = false,
  recentLogs = {},
  lastFocusedTerminal = nil,
  lastFocusedBrowser = nil,
  lockWatcher = nil,
  sessionLocked = false,
}

local function addBundleTokens(targetMap, raw)
  if type(raw) == "table" then
    for _, item in ipairs(raw) do
      if type(item) == "string" then
        for token in item:gmatch("[^%s,]+") do
          targetMap[token] = true
        end
      end
    end
  elseif type(raw) == "string" then
    for token in raw:gmatch("[^%s,]+") do
      targetMap[token] = true
    end
  end
end

local function rebuildBundleMaps()
  local term = {}
  local brow = {}
  for k, v in pairs(DEFAULT_TERMINAL_BUNDLES) do
    term[k] = v
  end
  for k, v in pairs(DEFAULT_BROWSER_BUNDLES) do
    brow[k] = v
  end

  local cfg = state.config
  if cfg and cfg.profiles then
    if cfg.profiles.terminal and cfg.profiles.terminal.bundleIDs then
      addBundleTokens(term, cfg.profiles.terminal.bundleIDs)
    end
    if cfg.profiles.browser and cfg.profiles.browser.bundleIDs then
      addBundleTokens(brow, cfg.profiles.browser.bundleIDs)
    end
  end

  -- Terminal priority: if a bundle ID is in both, remove it from browser
  for k, _ in pairs(term) do
    brow[k] = nil
  end

  state.terminalBundles = term
  state.browserBundles = brow
  M.terminalBundles = term
  M.browserBundles = brow
end
M.rebuildBundleMaps = rebuildBundleMaps
rebuildBundleMaps()

local function fileExists(path)
  return hs.fs.attributes(path, "mode") == "file"
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function copyFile(src, dst)
  local content = readFile(src)
  if not content then return false end
  local f = io.open(dst, "w")
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

local function loadConfig()
  if not fileExists(CONFIG_FILE) then
    if fileExists(EXAMPLE_FILE) then
      copyFile(EXAMPLE_FILE, CONFIG_FILE)
    else
      return {}
    end
  end
  local ok, data = pcall(hs.json.read, CONFIG_FILE)
  if ok and type(data) == "table" then
    return data
  end
  log.w("Failed to read remote_config.json, returning empty config")
  return {}
end

local function saveConfig(newConfig)
  state.config = newConfig
  rebuildBundleMaps()
  local ok, err = pcall(function()
    hs.json.write(newConfig, CONFIG_FILE, true, true)
  end)
  if not ok then
    log.ef("Failed to write remote_config.json: %s", tostring(err))
    return false
  end
  log.i("remote_config.json saved successfully")
  return true
end

-- Track frontmost apps to facilitate terminal <-> browser toggling
local function updateAppTrack()
  local app = hs.application.frontmostApplication()
  if not app then return end
  local bid = app:bundleID()
  local termMap = state.terminalBundles or DEFAULT_TERMINAL_BUNDLES
  local browMap = state.browserBundles or DEFAULT_BROWSER_BUNDLES
  if bid and termMap[bid] then
    state.lastFocusedTerminal = app
  elseif bid and browMap[bid] then
    state.lastFocusedBrowser = app
  end
end

local function currentProfile()
  local bid
  local appTitle = "System"
  if state._testBundleID then
    bid = state._testBundleID
    appTitle = bid
  else
    local app = hs.application.frontmostApplication()
    if app then
      bid = app:bundleID()
      appTitle = app:name() or bid or "System"
    end
  end

  local termMap = state.terminalBundles or DEFAULT_TERMINAL_BUNDLES
  local browMap = state.browserBundles or DEFAULT_BROWSER_BUNDLES

  if bid and termMap[bid] then
    return "terminal", appTitle
  elseif bid and browMap[bid] then
    return "browser", appTitle
  end
  return "global", appTitle
end
M.currentProfile = currentProfile

local function listenerRunning()
  return state.hidTask ~= nil and state.hidTask:isRunning()
end
M.listenerRunning = listenerRunning

-- Device isolation via hidutil
local function applyHidutil(vendorID, productID)
  local dev = (state.config and state.config.device) or {}
  local vid = vendorID or dev.vendorID or 10007
  local pid = productID or dev.productID or 12984

  if vid == 0 or pid == 0 then
    log.w("Invalid vendorID/productID, skipping hidutil setup")
    return false
  end

  local payload = hs.json.encode({ UserKeyMapping = hidutilUserKeyMapping() })
  local cmd = string.format("hidutil property --matching '{\"VendorID\":%d,\"ProductID\":%d}' --set '%s'",
    vid, pid, payload)
  log.i("Applying hidutil mapping for device VID=" .. vid .. " PID=" .. pid)
  local out, status = hs.execute(cmd)
  return status == true
end

local function applyHidutilIfListenerHealthy(vendorID, productID)
  if not listenerRunning() then
    return false
  end
  return applyHidutil(vendorID, productID)
end

local function getMatchingVidPid(vendorID, productID)
  local dev = (state.config and state.config.device) or {}
  local vid = vendorID or dev.vendorID or 10007
  local pid = productID or dev.productID or 12984
  return vid, pid
end

local function buildHidutilResetCommand(vendorID, productID)
  local vid, pid = getMatchingVidPid(vendorID, productID)
  return string.format("hidutil property --matching '{\"VendorID\":%d,\"ProductID\":%d}' --set '{\"UserKeyMapping\":[]}'", vid, pid)
end

M._hidutilResetCommand = function(vid, pid)
  return buildHidutilResetCommand(vid, pid)
end

local function resetHidutil(vendorID, productID)
  local vid, pid = getMatchingVidPid(vendorID, productID)
  if vid == 0 or pid == 0 then
    return
  end
  local cmd = buildHidutilResetCommand(vid, pid)
  log.i(string.format("Clearing hidutil user key mappings for VID=%d PID=%d", vid, pid))
  hs.execute(cmd)
end

local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

local KEY_ALIASES = {
  page_up = "pageup",
  page_down = "pagedown",
  return_key = "return",
  enter = "return",
  backspace = "delete",
  esc = "escape",
}

-- Key Stroke parsing helper
local function parseKeyStroke(str)
  if str:sub(1, 4) == "key:" then
    str = str:sub(5)
  end
  local parts = {}
  for part in string.gmatch(str, "[^+]+") do
    local cleaned = trim(part):lower()
    if cleaned ~= "" then
      table.insert(parts, cleaned)
    end
  end
  if #parts == 0 then return {}, nil end
  local rawKey = table.remove(parts)
  local key = KEY_ALIASES[rawKey] or rawKey
  local mods = parts
  return mods, key
end

local stopMouseTimer

-- Action Dispatcher
local function executeAction(actionStr, keyName, eventType)
  if not actionStr or actionStr == "" then return end
  if actionStr == "action:none" then return end
  logToFile("executeAction: [%s] -> %s (%s)", keyName, actionStr, eventType)
  if M._mockExecuteAction then
    M._mockExecuteAction(actionStr, keyName, eventType)
    return
  end

  -- 1. Voice Input (Seamless Hold-to-Talk)
  if actionStr == "action:voice_input" then
    if VoiceInput ~= nil then
      if eventType == "down" then
        logToFile("VoiceInput: start() invoked")
        if VoiceInput.start then VoiceInput:start() end
      elseif eventType == "up" then
        logToFile("VoiceInput: stop() invoked")
        if VoiceInput.stop then VoiceInput:stop() end
      end
    end
    return
  end

  -- For other actions, fire on tap or hold (not on raw key up)
  if eventType == "up" then return end

  if actionStr == "key:return" and VoiceInput then
    if VoiceInput.active or VoiceInput.stopping or VoiceInput.pastePending then
      hs.alert.show("语音尚未完成，请稍后按 OK 发送", 1)
      return
    end
    if VoiceInput.pendingText and VoiceInput.resumePending then
      VoiceInput.resumePending()
      return
    end
  end

  if actionStr == "key:ctrl+tab" or actionStr == "key:ctrl+shift+tab"
      or actionStr == "action:focus_iterm" then
    state.navigationEpoch = state.navigationEpoch + 1
    state.reviewMode = false
  end

  if actionStr == "action:focus_iterm" then
    state.reviewMode = false
    hs.application.launchOrFocusByBundleID("com.googlecode.iterm2")
    return
  end

  if actionStr == "action:toggle_review" then
    state.reviewMode = not state.reviewMode
    hs.alert.show(state.reviewMode and "查看输出：上下翻页，TV 退出，返回删除" or "已回到终端输入", 1.5)
    return
  end

  -- 2. Window Switcher (Alt-Tab)
  if actionStr == "action:window_switcher" then
    logToFile("Executing window_switcher via WindowSwitcher.next")
    if WindowSwitcher and WindowSwitcher.next then
      WindowSwitcher.next({ source = "remote" })
    end
    return
  end

  -- 3. App Toggle (Terminal <-> Browser)
  if actionStr == "action:toggle_app" then
    local pName, _ = currentProfile()
    if pName == "terminal" then
      if state.lastFocusedBrowser and state.lastFocusedBrowser:isRunning() then
        state.lastFocusedBrowser:activate()
      elseif not hs.application.launchOrFocus("Google Chrome") then
        hs.application.launchOrFocus("Safari")
      end
    else
      if state.lastFocusedTerminal and state.lastFocusedTerminal:isRunning() then
        state.lastFocusedTerminal:activate()
      elseif not hs.application.launchOrFocus("iTerm") then
        if not hs.application.launchOrFocus("Ghostty") then
          hs.application.launchOrFocus("Terminal")
        end
      end
    end
    return
  end

  if actionStr == "action:switch_to_browser" then
    if state.lastFocusedBrowser and state.lastFocusedBrowser:isRunning() then
      state.lastFocusedBrowser:activate()
    elseif not hs.application.launchOrFocus("Google Chrome") then
      hs.application.launchOrFocus("Safari")
    end
    return
  end

  if actionStr == "action:switch_to_terminal" then
    if state.lastFocusedTerminal and state.lastFocusedTerminal:isRunning() then
      state.lastFocusedTerminal:activate()
    elseif not hs.application.launchOrFocus("iTerm") then
      if not hs.application.launchOrFocus("Ghostty") then
        hs.application.launchOrFocus("Terminal")
      end
    end
    return
  end

  -- 4. Dashboard Toggle
  if actionStr == "action:toggle_dashboard" then
    M.toggleDashboard()
    return
  end

  -- 5. Mouse Mode
  if actionStr == "action:toggle_mouse_mode" then
    if state.mouseMode then
      stopMouseTimer()
      state.mouseMode = false
    else
      state.mouseMode = true
    end
    hs.alert.show(state.mouseMode and "🖱️ 遥控器已开启鼠标模式" or "⌨️ 遥控器已恢复按键模式", 1.5)
    return
  end

  -- 6. Mission Control & Display Sleep
  if actionStr == "action:mission_control" then
    hs.eventtap.keyStroke({ "ctrl" }, "up", 10000)
    return
  end

  if actionStr == "action:show_desktop" then
    hs.eventtap.keyStroke({ "cmd" }, "f3", 10000)
    return
  end

  if actionStr == "action:focus_input" then
    local app = hs.application.frontmostApplication()
    if app then
      local bid = app:bundleID() or ""
      local browMap = state.browserBundles or DEFAULT_BROWSER_BUNDLES
      if browMap[bid] then
        hs.eventtap.keyStroke({ "cmd" }, "l", 10000)
      else
        app:activate()
      end
    end
    return
  end

  if actionStr == "action:display_sleep" then
    logToFile("Executing display sleep (pmset displaysleepnow)")
    hs.execute("pmset displaysleepnow")
    return
  end

  if actionStr == "action:escape_layer" then
    stopMouseTimer()
    state.mouseMode = false
    state.reviewMode = false
    if WindowSwitcher and WindowSwitcher.cancel then
      WindowSwitcher.cancel()
    end
    hs.alert.show("已重置遥控状态", 1)
    return
  end

  -- 7. Macro actions
  if actionStr == "macro:approve_agent" then
    local settings = (state.config and state.config.settings) or {}
    if settings.dangerousMacros == false then
      logToFile("macro:approve_agent skipped because dangerousMacros is false")
      hs.alert.show("已禁用危险宏 (dangerousMacros=false)", 1)
      return
    end
    hs.eventtap.keyStroke({}, "y", 10000)
    hs.timer.doAfter(0.04, function()
      hs.eventtap.keyStroke({}, "return", 10000)
    end)
    return
  end

  if actionStr == "macro:restart_dev_server" then
    local settings = (state.config and state.config.settings) or {}
    if settings.dangerousMacros == false then
      logToFile("macro:restart_dev_server skipped because dangerousMacros is false")
      hs.alert.show("已禁用危险宏 (dangerousMacros=false)", 1)
      return
    end
    hs.eventtap.keyStroke({ "ctrl" }, "c", 10000)
    hs.timer.doAfter(0.08, function()
      hs.eventtap.keyStroke({}, "up", 10000)
      hs.timer.doAfter(0.04, function()
        hs.eventtap.keyStroke({}, "return", 10000)
      end)
    end)
    return
  end

  if actionStr == "macro:tmux_next_window" then
    hs.eventtap.keyStroke({ "ctrl" }, "b", 10000)
    hs.timer.doAfter(0.04, function()
      hs.eventtap.keyStroke({}, "n", 10000)
    end)
    return
  end

  if actionStr == "macro:tmux_prev_window" then
    hs.eventtap.keyStroke({ "ctrl" }, "b", 10000)
    hs.timer.doAfter(0.04, function()
      hs.eventtap.keyStroke({}, "p", 10000)
    end)
    return
  end

  -- Volume controls via macOS system media keys
  if actionStr == "key:volume_up" or actionStr == "action:volume_up" then
    logToFile("Adjusting system volume UP")
    hs.eventtap.event.newSystemKeyEvent("SOUND_UP", true):post()
    hs.eventtap.event.newSystemKeyEvent("SOUND_UP", false):post()
    return
  end

  if actionStr == "key:volume_down" or actionStr == "action:volume_down" then
    logToFile("Adjusting system volume DOWN")
    hs.eventtap.event.newSystemKeyEvent("SOUND_DOWN", true):post()
    hs.eventtap.event.newSystemKeyEvent("SOUND_DOWN", false):post()
    return
  end

  if actionStr == "action:mute" or actionStr == "key:mute" then
    logToFile("Toggling system mute")
    hs.eventtap.event.newSystemKeyEvent("MUTE", true):post()
    hs.eventtap.event.newSystemKeyEvent("MUTE", false):post()
    return
  end

  if actionStr == "action:media_play_pause" or actionStr == "key:play_pause" then
    logToFile("Toggling media play/pause")
    hs.eventtap.event.newSystemKeyEvent("PLAY", true):post()
    hs.eventtap.event.newSystemKeyEvent("PLAY", false):post()
    return
  end

  if actionStr == "action:scroll_up" then
    hs.eventtap.scrollWheel({ 0, 5 }, {}, "line")
    return
  end

  if actionStr == "action:scroll_down" then
    hs.eventtap.scrollWheel({ 0, -5 }, {}, "line")
    return
  end

  -- 8. Direct Key Stroke (e.g. key:ctrl+c, key:shift+cmd+r, key:return, key:delete)
  if actionStr:match("^key:") then
    local spec = actionStr:sub(5)
    local mods, key = parseKeyStroke(spec)
    if key then
      logToFile("Executing keyStroke: mods=%s key=%s (from %s)", hs.inspect(mods), key, spec)
      local ok, err = pcall(function()
        hs.eventtap.keyStroke(mods, key, 10000)
      end)
      if not ok then
        logToFile("Error executing keyStroke: %s", tostring(err))
      end
    else
      logToFile("Failed to parse keyStroke: %s", spec)
    end
    return
  end
end

-- Resolves the action configured for a key under current app profile
local function resolveKeyAction(keyName, triggerType, profileOverride)
  local profileName = profileOverride
  if not profileName then
    profileName, _ = currentProfile()
  end
  local cfg = state.config or loadConfig()
  local profiles = (cfg and cfg.profiles) or {}
  local p = profiles[profileName] or profiles["global"] or {}
  local keyDefs = p.keys and p.keys[keyName]
  if not keyDefs and profiles["global"] then
    keyDefs = profiles["global"].keys and profiles["global"].keys[keyName]
  end
  if keyDefs then
    if triggerType == "double_tap" then
      return keyDefs["double_tap"]
    end
    return keyDefs[triggerType] or keyDefs["tap"]
  end
  return nil
end

local function pushEventToDashboard(keyName, eventType, action, frontApp)
  if state.dashboard then
    local payload = hs.json.encode({
      keyName = keyName,
      eventType = eventType,
      action = action or "--",
      frontApp = frontApp or "System",
    })
    local js = string.format("if (window.onRemoteKeyEvent) { window.onRemoteKeyEvent(%s); }", payload)
    pcall(function()
      state.dashboard:evaluateJavaScript(js)
    end)
  end
end

stopMouseTimer = function()
  if state.mouseTimer ~= nil then
    pcall(function() state.mouseTimer:stop() end)
    state.mouseTimer = nil
  end
  state.mouseHeldKey = nil
end
M.stopMouseTimer = stopMouseTimer

-- A missing key-up must not leave input running after disconnect, lock or restart.
local function clearInputState(stopAllVoice)
  state.inputEpoch = state.inputEpoch + 1
  local remoteVoiceActive = false
  for _, value in pairs(state.activeKeys) do
    if value == "voice" then remoteVoiceActive = true end
  end
  stopMouseTimer()
  for _, name in ipairs({ "keyTimers", "doubleTapTimers", "repeatTimers" }) do
    for _, timer in pairs(state[name]) do timer:stop() end
    state[name] = {}
  end
  state.pendingDoubleTap = {}
  state.activeKeys = {}
  state.pressContexts = {}
  state.mouseMode = false
  state.reviewMode = false
  if (stopAllVoice or remoteVoiceActive) and VoiceInput and VoiceInput.active and VoiceInput.stop then
    VoiceInput.stop()
  end
end

local function setDeviceConnected(connected)
  -- One remote can expose several HID services, each with its own callback.
  if connected then
    state.connectedDeviceCount = state.connectedDeviceCount + 1
    if state.connectedDeviceCount == 1 and state.eventtap then state.eventtap:start() end
  else
    state.connectedDeviceCount = math.max(0, state.connectedDeviceCount - 1)
    if state.connectedDeviceCount == 0 then
      clearInputState()
      if state.eventtap then state.eventtap:stop() end
    end
  end
end

local function doMouseStep(keyName, factor)
  factor = factor or 1
  if M._mockExecuteAction then
    M._mockExecuteAction("mouse:" .. keyName, keyName, "step")
    return
  end
  local settings = (state.config and state.config.settings) or {}
  local speed = settings.mouseSpeed or 14
  local step = speed * factor

  local pos = hs.mouse.absolutePosition()
  local dx, dy = 0, 0
  if keyName == "up" then dy = -step
  elseif keyName == "down" then dy = step
  elseif keyName == "left" then dx = -step
  elseif keyName == "right" then dx = step
  elseif keyName == "volume_up" then
    local lines = math.max(1, math.floor(4 * factor))
    hs.eventtap.scrollWheel({ 0, lines }, {}, "line")
    return
  elseif keyName == "volume_down" then
    local lines = math.max(1, math.floor(4 * factor))
    hs.eventtap.scrollWheel({ 0, -lines }, {}, "line")
    return
  end

  if dx ~= 0 or dy ~= 0 then
    hs.mouse.absolutePosition({ x = pos.x + dx, y = pos.y + dy })
  end
end

-- Core Key Input Handler (Accepts either virtual keyCode or direct keyName string)
local function handleKeyEvent(keyOrCode, isDown, isRepeat)
  local keyName
  local keyCode = 0
  if type(keyOrCode) == "string" then
    keyName = keyOrCode
  else
    keyCode = keyOrCode
    keyName = TRANSIT_KEY_MAP[keyOrCode]
  end
  if not keyName then
    return false  -- real keyboard / login window MUST pass through
  end
  if keyName == "isolated_remote" then return true end
  if state.sessionLocked then
    stopMouseTimer()
    state.activeKeys[keyName] = nil
    if state.keyTimers[keyName] then
      state.keyTimers[keyName]:stop()
      state.keyTimers[keyName] = nil
    end
    if state.doubleTapTimers[keyName] then
      state.doubleTapTimers[keyName]:stop()
      state.doubleTapTimers[keyName] = nil
    end
    if state.repeatTimers[keyName] then
      state.repeatTimers[keyName]:stop()
      state.repeatTimers[keyName] = nil
    end
    state.pressContexts[keyName] = nil
    return true  -- swallow only known remote transit / IOHID names
  end

  updateAppTrack()
  local profileName, appTitle = currentProfile()
  logToFile("handleKeyEvent: keyName=%s keyCode=%s isDown=%s isRepeat=%s profile=%s app=%s",
    keyName, tostring(keyCode), tostring(isDown), tostring(isRepeat), profileName, appTitle or "System")

  local settings = state.config.settings or {}
  local targetBundleID = settings.targetBundleID
  local app = hs.application.frontmostApplication()
  local bid = state._testBundleID or (app and app:bundleID())
  -- Always finish a voice press even if focus changed while recording.
  if not isDown and state.activeKeys[keyName] == "voice" then
    state.activeKeys[keyName] = nil
    executeAction("action:voice_input", keyName, "up")
    return true
  end
  if targetBundleID and bid ~= targetBundleID and keyName ~= "home" and keyName ~= "power" then
    if state.keyTimers[keyName] then state.keyTimers[keyName]:stop(); state.keyTimers[keyName] = nil end
    if state.repeatTimers[keyName] then state.repeatTimers[keyName]:stop(); state.repeatTimers[keyName] = nil end
    state.activeKeys[keyName] = nil
    state.pressContexts[keyName] = nil
    if isDown and not isRepeat then hs.alert.show("按主页回到 iTerm2", 1) end
    return true
  end

  if state.reviewMode and keyName == "back" and isDown then
    state.reviewMode = false
    -- Continue to the configured deletion action on this same press.
  end

  -- Window switcher interception when active
  if WindowSwitcher and WindowSwitcher.isVisible and WindowSwitcher.isVisible() then
    if isDown then
      if keyName == "down" or keyName == "right" then
        WindowSwitcher.next({ source = "remote" })
        pushEventToDashboard(keyName, "down", "switcher:next", appTitle)
        return true
      elseif keyName == "up" or keyName == "left" then
        WindowSwitcher.previous({ source = "remote" })
        pushEventToDashboard(keyName, "down", "switcher:previous", appTitle)
        return true
      elseif keyName == "ok" then
        WindowSwitcher.confirm()
        pushEventToDashboard(keyName, "down", "switcher:confirm", appTitle)
        return true
      elseif keyName == "back" or keyName == "menu" then
        if WindowSwitcher.cancel then WindowSwitcher.cancel() end
        pushEventToDashboard(keyName, "down", "switcher:cancel", appTitle)
        return true
      end
    else
      return true
    end
  end

  -- Mouse mode interception
  if state.mouseMode and keyName ~= "power" and keyName ~= "voice" then
    if isDown then
      if keyName == "ok" or keyName == "back" then
        stopMouseTimer()
        if M._mockExecuteAction then
          M._mockExecuteAction("mouse:" .. keyName, keyName, "click")
        else
          local pos = hs.mouse.absolutePosition()
          if keyName == "ok" then
            hs.eventtap.leftClick(pos)
          else
            hs.eventtap.rightClick(pos)
          end
        end
        pushEventToDashboard(keyName, "mouse", keyName == "ok" and "left_click" or "right_click", appTitle)
        return true
      elseif keyName == "up" or keyName == "down" or keyName == "left" or keyName == "right"
          or keyName == "volume_up" or keyName == "volume_down" then
        if state.mouseHeldKey == keyName then
          return true
        end
        stopMouseTimer()
        state.mouseHeldKey = keyName

        local ticks = 0
        local settings = (state.config and state.config.settings) or {}
        local accel = settings.mouseAcceleration or 1.2
        local function doStep()
          local factor = math.min(4, accel ^ (ticks / 8))
          doMouseStep(keyName, factor)
          ticks = ticks + 1
        end

        doStep()
        local mouseEpoch = state.inputEpoch
        state.mouseTimer = hs.timer.doEvery(0.016, function()
          if mouseEpoch ~= state.inputEpoch or not state.mouseMode or state.mouseHeldKey ~= keyName then return end
          doStep()
        end)

        local actionDesc = (keyName:find("volume") and "scroll") or "move_pointer"
        pushEventToDashboard(keyName, "mouse", actionDesc, appTitle)
        return true
      else
        stopMouseTimer()
        return true
      end
    else
      -- KeyUp in mouse mode
      if state.mouseHeldKey == keyName then
        stopMouseTimer()
      end
      return true
    end
  end

  -- Configurable voice key check (hold-to-talk on down/up if tap OR hold mapped to action:voice_input)
  local tapAction = resolveKeyAction(keyName, "tap")
  local holdAction = resolveKeyAction(keyName, "hold")
  local isVoiceHoldToTalk = (tapAction == "action:voice_input" or holdAction == "action:voice_input")

  if isVoiceHoldToTalk then
    if isDown then
      if isRepeat or state.activeKeys[keyName] then
        return true
      end
      state.activeKeys[keyName] = "voice"
      executeAction("action:voice_input", keyName, "down")
      pushEventToDashboard(keyName, "down", "action:voice_input", appTitle)
      return true
    else
      state.activeKeys[keyName] = nil
      executeAction("action:voice_input", keyName, "up")
      pushEventToDashboard(keyName, "up", "action:voice_input", appTitle)
      return true
    end
  end

  -- Repeatable keys fire on down; each key can choose its own repeat cadence.
  local keyDefs = state.config.profiles[profileName] and state.config.profiles[profileName].keys[keyName]
  if keyDefs and keyDefs.repeatable then
    if isDown then
      if isRepeat or state.activeKeys[keyName] then return true end
      state.activeKeys[keyName] = true
      local context = InputTarget.capture()
      local action = tapAction
      if state.reviewMode and (keyName == "up" or keyName == "down") then
        action = keyName == "up" and "key:shift+pageup" or "key:shift+pagedown"
      end
      local repeatEpoch = state.inputEpoch
      local function step()
        if repeatEpoch ~= state.inputEpoch or not state.activeKeys[keyName] then return false end
        if state.sessionLocked or not InputTarget.matches(context, InputTarget.capture()) then
          if state.repeatTimers[keyName] then state.repeatTimers[keyName]:stop(); state.repeatTimers[keyName] = nil end
          state.activeKeys[keyName] = nil
          return false
        end
        executeAction(action, keyName, "repeat")
        return true
      end
      executeAction(action, keyName, "down")
      state.repeatTimers[keyName] = hs.timer.doAfter((keyDefs.repeatDelayMs or settings.repeatDelayMs or 350) / 1000, function()
        if not step() then return end
        state.repeatTimers[keyName] = hs.timer.doEvery((keyDefs.repeatIntervalMs or settings.repeatIntervalMs or 90) / 1000, step)
      end)
    else
      if state.repeatTimers[keyName] then state.repeatTimers[keyName]:stop(); state.repeatTimers[keyName] = nil end
      state.activeKeys[keyName] = nil
    end
    return true
  end

  local holdMs = (keyDefs and keyDefs.holdThresholdMs) or settings.holdThresholdMs or 350
  local doubleIntervalMs = (state.config.settings and state.config.settings.doubleClickIntervalMs) or 250

  if isDown then
    -- If key is already marked active, this is a hardware repeat packet while held.
    -- Do not reset the timer; keep counting towards hold threshold!
    if isRepeat or state.activeKeys[keyName] then
      return true
    end

    state.activeKeys[keyName] = true
    local context = { profile = profileName, target = InputTarget.capture() }
    state.pressContexts[keyName] = context
    local function sameTarget()
      return keyName == "home" or keyName == "power" or InputTarget.matches(context.target, InputTarget.capture())
    end

    -- Immediate visual feedback on KeyDown in Dashboard
    pushEventToDashboard(keyName, "down", tapAction or "--", appTitle)

    -- Check if there is a pending double-tap timer for this key
    if state.doubleTapTimers[keyName] then
      state.doubleTapTimers[keyName]:stop()
      state.doubleTapTimers[keyName] = nil
      state.pendingDoubleTap[keyName] = true
    end

    -- Setup hold timer
    if state.keyTimers[keyName] then
      state.keyTimers[keyName]:stop()
    end
    local t
    t = hs.timer.doAfter(holdMs / 1000, function()
      if state.keyTimers[keyName] ~= t then return end
      state.keyTimers[keyName] = nil
      state.pendingDoubleTap[keyName] = nil
      if state.activeKeys[keyName] and sameTarget() then
        local action = resolveKeyAction(keyName, "hold", context.profile)
        executeAction(action, keyName, "hold")
        pushEventToDashboard(keyName, "hold", action, appTitle)
      end
    end)
    state.keyTimers[keyName] = t
    return true
  else
    -- KeyUp
    state.activeKeys[keyName] = nil
    local context = state.pressContexts[keyName]
    state.pressContexts[keyName] = nil
    if not context or (keyName ~= "home" and keyName ~= "power"
        and not InputTarget.matches(context.target, InputTarget.capture())) then
      if state.keyTimers[keyName] then state.keyTimers[keyName]:stop(); state.keyTimers[keyName] = nil end
      return true
    end

    -- If hold timer was still pending, this was a short press (Tap or Double Tap)
    if state.keyTimers[keyName] ~= nil then
      state.keyTimers[keyName]:stop()
      state.keyTimers[keyName] = nil

      -- Was this the second tap of a double-tap?
      if state.pendingDoubleTap[keyName] then
        state.pendingDoubleTap[keyName] = nil
        local doubleAction = resolveKeyAction(keyName, "double_tap", context.profile)
        if doubleAction then
          executeAction(doubleAction, keyName, "double_tap")
          pushEventToDashboard(keyName, "double_tap", doubleAction, appTitle)
          return true
        end
      end

      -- Check if current profile has double_tap configured for this key
      local doubleTapAction = resolveKeyAction(keyName, "double_tap", context.profile)
      if doubleTapAction then
        -- Delay execution to detect potential second tap
        local t
        t = hs.timer.doAfter(doubleIntervalMs / 1000, function()
          if state.doubleTapTimers[keyName] ~= t then return end
          state.doubleTapTimers[keyName] = nil
          if keyName ~= "home" and keyName ~= "power"
              and not InputTarget.matches(context.target, InputTarget.capture()) then return end
          local action = resolveKeyAction(keyName, "tap", context.profile)
          executeAction(action, keyName, "tap")
          pushEventToDashboard(keyName, "tap", action, appTitle)
        end)
        state.doubleTapTimers[keyName] = t
      else
        -- No double-tap configured: fire tap immediately with zero delay
        local action = resolveKeyAction(keyName, "tap", context.profile)
        executeAction(action, keyName, "tap")
        pushEventToDashboard(keyName, "tap", action, appTitle)
      end
    else
      -- Hold was already triggered, ensure pending double-tap is cleared
      state.pendingDoubleTap[keyName] = nil
    end
    return true
  end
end

-- Setup Global Event Tap
local function setupEventTap()
  if state.eventtap then
    state.eventtap:stop()
  end

  state.eventtap = hs.eventtap.new({
    hs.eventtap.event.types.keyDown,
    hs.eventtap.event.types.keyUp,
  }, function(event)
    -- Button identity comes exclusively from IOHID; swallow only inert F20.
    return TRANSIT_KEY_MAP[event:getKeyCode()] ~= nil
  end)
  -- Start only when IOHID reports a connected device, before applying isolation.
  log.i("RemoteControl eventtap ready; waiting for a device")
end

-- IOHID helper for keys that hidutil cannot remap (e.g. Back button 0xF1)
-- Listener fallback. Do NOT use pkill -f.
-- ps columns: pid, comm (basename), args (full argv)
local function reapOrphanListeners()
  local bin = resolveFile("listener", "remote_hid_listener")
  local out = hs.execute("/bin/ps -Ao pid=,comm=,args=") or ""
  for line in out:gmatch("[^\n]+") do
    local pid, comm, args = line:match("^%s*(%d+)%s+(%S+)%s+(.*)$")
    if pid and comm and args then
      local isListener = (comm == "listener" or comm == "remote_hid_listener")
      local startsWithBin = (args:sub(1, #bin) == bin)
      local isSwift = args:find(".swift", 1, true) ~= nil
      if isListener and startsWithBin and not isSwift then
        hs.execute("/bin/kill " .. pid)
      end
    end
  end
end

local function killOwnListener()
  clearInputState()
  state.connectedDeviceCount = 0
  if state.eventtap then state.eventtap:stop() end
  local task = state.hidTask
  state.hidTask = nil  -- MUST before terminate, so completion is a no-op
  if task ~= nil then
    local pid = task:pid()
    pcall(function() task:terminate() end)
    if pid ~= nil then
      hs.execute("/bin/kill " .. tostring(pid))
    end
  end
  reapOrphanListeners()  -- see pipeline below; never pkill -f listener.swift
end

-- IOHID helper for keys that hidutil cannot remap (e.g. Back button 0xF1)
local function startHidListener(forceApplyHidutil)
  killOwnListener()

  local helperBin = resolveFile("listener", "remote_hid_listener")
  local swiftSrc = resolveFile("listener.swift", "remote_hid_listener.swift")
  if not fileExists(helperBin) and fileExists(swiftSrc) then
    log.i("listener binary not found, auto-compiling from Swift source...")
    hs.execute(string.format("swiftc -O '%s' -o '%s'", swiftSrc, helperBin))
  end

  if not fileExists(helperBin) then
    log.w("listener binary not found at " .. helperBin)
    return
  end

  local vid = (state.config and state.config.device and state.config.device.vendorID) or 10007
  local pid = (state.config and state.config.device and state.config.device.productID) or 12984
  local args = { "--vid", tostring(vid), "--pid", tostring(pid) }

  local stdoutBuffer = ""
  local taskRef
  taskRef = hs.task.new(helperBin, function(code, stdout, stderr)
    if state.hidTask ~= taskRef then
      return  -- supervised restart; do not resetHidutil
    end
    state.hidTask = nil
    clearInputState()
    state.connectedDeviceCount = 0
    if not state.sessionLocked then
      resetHidutil()
      if state.eventtap then state.eventtap:stop() end
    end
  end, function(task, stdout, stderr)
    if state.hidTask ~= taskRef then return false end
    if stdout and stdout ~= "" then
      stdoutBuffer = stdoutBuffer .. stdout
      while true do
        local nlPos = stdoutBuffer:find("\n")
        if not nlPos then break end
        local line = stdoutBuffer:sub(1, nlPos - 1):gsub("\r", "")
        stdoutBuffer = stdoutBuffer:sub(nlPos + 1)
        if line ~= "" then
          local ok, event = pcall(hs.json.decode, line)
          if ok and type(event) == "table" then
            if event.key then
              logToFile("hid_key: %s (down=%s)", event.key, tostring(event.down))
              handleKeyEvent(event.key, event.down == true, false)
            elseif event.event == "device_matched" then
              setDeviceConnected(true)
              logToFile("Remote control connected via IOHID, applying hidutil mapping...")
              if state.sessionLocked or forceApplyHidutil or (state.config.device and state.config.device.autoApplyHidutil) then
                applyHidutilIfListenerHealthy(vid, pid)
              end
              M.refreshDashboardData()
            elseif event.event == "device_removed" then
              logToFile("Remote control disconnected")
              setDeviceConnected(false)
              M.refreshDashboardData()
            elseif event.error then
              logToFile("hid_error: %s", tostring(event.error))
            end
          end
        end
      end
    end
    return true
  end, args)

  state.hidTask = taskRef
  if state.hidTask:start() then
    log.i("remote_hid_listener started successfully for Back button (0xF1)")
  else
    log.ef("Failed to start remote_hid_listener task")
    state.hidTask = nil
  end
end

local function stopHidListener()
  killOwnListener()
end

-- Control Panel Webview Management
local function setupDashboard()
  if state.dashboard then return end

  state.dashboardUserContent = hs.webview.usercontent.new("remoteControl")
  state.dashboardUserContent:setCallback(function(msg)
    local body = msg.body
    if type(body) ~= "table" then return end
    local action = body.action
    local payload = body.payload

    if action == "ready" then
      M.refreshDashboardData()
    elseif action == "hide" then
      M.hideDashboard()
    elseif action == "save_config" then
      saveConfig(payload)
      hs.alert.show("遥控器配置已保存并生效", 1)
      M.refreshDashboardData()
    elseif action == "apply_device" then
      if payload then
        killOwnListener()
        resetHidutil() -- clear the old VID/PID before changing the target
        state.config.device = payload
        saveConfig(state.config)
        startHidListener(true)
        if not listenerRunning() then
          resetHidutil(payload.vendorID, payload.productID)
        end
        hs.alert.show(listenerRunning() and "监听已启动，设备连接后自动应用隔离" or "监听启动失败，请检查 VID/PID", 2)
      end
    elseif action == "reset_hidutil" then
      resetHidutil()
      hs.alert.show("已还原本遥控器 hidutil 映射", 1.5)
    elseif action == "detect_devices" or action == "refresh_status" then
      M.refreshDashboardData()
    end
  end)

  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local frame = screen:frame()
  local w, h = 860, 620
  local rect = {
    x = math.floor(frame.x + (frame.w - w) / 2),
    y = math.floor(frame.y + (frame.h - h) / 2),
    w = w,
    h = h,
  }

  state.dashboard = hs.webview.new(rect, {
    developerExtras = true,
  }, state.dashboardUserContent)

  state.dashboard:windowTitle("遥控器控制中心 - Remote Control")
  state.dashboard:windowStyle(
    hs.webview.windowMasks.titled |
    hs.webview.windowMasks.closable |
    hs.webview.windowMasks.resizable
  )
  state.dashboard:allowTextEntry(true)
  pcall(function()
    state.dashboard:level(hs.drawing.windowLevels.floating or 3)
    state.dashboard:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "ignoresCycle" })
  end)
  -- Closing with Esc or the window 'X' will hide it; the background service remains running!
  state.dashboard:closeOnEscape(true)
  state.dashboard:deleteOnClose(false)

  local htmlContent = readFile(DASHBOARD_HTML)
  if htmlContent then
    state.dashboard:html(htmlContent, "file://" .. moduleDir)
  end
end

function M.refreshDashboardData()
  if not state.dashboard then return end

  -- Push full config
  local cfgJson = hs.json.encode(state.config)
  state.dashboard:evaluateJavaScript(string.format("if (window.onReceiveConfig) { window.onReceiveConfig(%s); }", cfgJson))

  -- Query hidutil list
  local hidOut = hs.execute("hidutil list")
  local formattedDevices = ""
  if type(hidOut) == "string" then
    for line in hidOut:gmatch("[^\r\n]+") do
      local safeLine = line:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
      formattedDevices = formattedDevices .. safeLine .. "<br/>"
    end
  end

  local _, appTitle = currentProfile()
  local recentLogLines = {}
  local f = io.open(DEBUG_LOG, "r")
  if f then
    local allLines = {}
    for l in f:lines() do
      table.insert(allLines, l)
    end
    f:close()
    local startIdx = math.max(1, #allLines - 20)
    for idx = startIdx, #allLines do
      table.insert(recentLogLines, allLines[idx])
    end
  end

  local statusJson = hs.json.encode({
    frontApp = appTitle or "System",
    activeLayer = state.mouseMode and "鼠标模式" or "按键标准模式",
    hidDevices = formattedDevices ~= "" and formattedDevices or "未能识别到外部 HID 设备",
    recentLogs = recentLogLines,
    listenerRunning = listenerRunning(),
    voiceStatus = VoiceInput and "已加载" or "未加载",
  })
  state.dashboard:evaluateJavaScript(string.format("if (window.onUpdateStatus) { window.onUpdateStatus(%s); }", statusJson))
end

function M.showDashboard()
  setupDashboard()

  -- Position on the active display where user's mouse currently is
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  if screen and state.dashboard then
    local frame = screen:frame()
    local w, h = 860, 620
    local rect = {
      x = math.floor(frame.x + (frame.w - w) / 2),
      y = math.floor(frame.y + (frame.h - h) / 2),
      w = w,
      h = h,
    }
    pcall(function() state.dashboard:frame(rect) end)
  end

  pcall(function()
    state.dashboard:level(hs.drawing.windowLevels.floating or 3)
    state.dashboard:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "ignoresCycle" })
  end)

  state.dashboard:show()
  state.isDashboardVisible = true

  pcall(function()
    local app = hs.application.get("org.hammerspoon.Hammerspoon") or hs.application.get("Hammerspoon")
    if app then
      app:activate(true)
    end
    local win = state.dashboard:hswindow()
    if win then
      win:raise()
      win:focus()
    end
  end)

  M.refreshDashboardData()
end

function M.hideDashboard()
  if state.dashboard then
    state.dashboard:hide()
    state.isDashboardVisible = false
    hs.alert.show("控制面板已隐藏 (服务持续在后台常驻)", 0.8)
  end
end

function M.toggleDashboard()
  if state.dashboard and state.isDashboardVisible then
    M.hideDashboard()
  else
    M.showDashboard()
  end
end


local function onSessionLock()
  state.sessionLocked = true
  clearInputState(true)
  if state.connectedDeviceCount > 0 then
    if state.eventtap then state.eventtap:start() end
    applyHidutil() -- retain isolation while locked, even if the listener exits
  end
end

local function onSessionUnlock()
  state.sessionLocked = false
  if listenerRunning() then
    applyHidutilIfListenerHealthy()
  else
    resetHidutil()  -- avoid dead keys while unlocked
    if state.eventtap then state.eventtap:stop() end
  end
end

local function attachLockWatcher()
  if state.lockWatcher then
    pcall(function() state.lockWatcher:stop() end)
  end
  state.lockWatcher = hs.caffeinate.watcher.new(function(event)
    local w = hs.caffeinate.watcher
    if event == w.screensDidLock or event == w.screensaverDidStart then
      onSessionLock()
    elseif event == w.screensDidUnlock or event == w.screensaverDidStop then
      onSessionUnlock()
    end
  end)
  state.lockWatcher:start()
  local out = hs.execute("/usr/sbin/ioreg -n Root -d 1 -w 0") or ""
  if out:find('"CGSSessionScreenIsLocked"%s*=%s*Yes') then
    onSessionLock()  -- already locked at start/reload; watcher will not re-fire
  end
end

function M.stop()
  killOwnListener()
  if state.eventtap then state.eventtap:stop(); state.eventtap = nil end
  if state.hotkey then state.hotkey:delete(); state.hotkey = nil end
  if state.dashboard then pcall(function() state.dashboard:delete() end); state.dashboard = nil end
  if state.lockWatcher then pcall(function() state.lockWatcher:stop() end); state.lockWatcher = nil end
  resetHidutil()
end

function M.start(options)
  M.stop()  -- still first line
  options = options or {}
  state.config = loadConfig()
  rebuildTransitKeyMap()   -- add in PR 2 (HIDUTIL_MAPPINGS exists)
  rebuildBundleMaps()      -- add in PR 3 (bundle routing)
  setupEventTap()
  resetHidutil()
  startHidListener()
  state.hotkey = hs.hotkey.bind({ "alt", "shift" }, "r", function()
    M.toggleDashboard()
  end)
  attachLockWatcher()  -- PR 2, AFTER startHidListener; probes ioreg if already locked
  local prevShutdown = hs.shutdownCallback
  hs.shutdownCallback = function()
    M.stop()
    if type(prevShutdown) == "function" then prevShutdown() end
  end
  return M
end

M._state = state
M.logPath = DEBUG_LOG
M.logToFile = logToFile
M.loadConfig = loadConfig
M.TRANSIT_KEY_MAP = TRANSIT_KEY_MAP
M.parseKeyStroke = parseKeyStroke
M.resolveKeyAction = resolveKeyAction
M.decodeHidUsage = function(page, usage)
  if page == 0x07 then
    local map = {
      [0x52] = "up", [0x51] = "down", [0x50] = "left", [0x4F] = "right",
      [0x28] = "ok", [0x3E] = "voice", [0xF1] = "back", [0x65] = "menu",
      [0x35] = "tv", [0x80] = "volume_up", [0x81] = "volume_down",
      [0x4A] = "home", [0x66] = "power"
    }
    return map[usage]
  elseif page == 0x0C then
    local map = {
      [0x0224] = "back", [0xE9] = "volume_up", [0xEA] = "volume_down",
      [0x30] = "power", [0x223] = "home"
    }
    return map[usage]
  end
  return nil
end
M.testTriggerKey = handleKeyEvent
M.testFireTimer = function(keyName)
  local timer = state.keyTimers[keyName]
  if not timer then return end
  timer:stop()
  state.keyTimers[keyName] = nil
  state.pendingDoubleTap[keyName] = nil
  if state.activeKeys[keyName] then
    local action = resolveKeyAction(keyName, "hold")
    executeAction(action, keyName, "hold")
    pushEventToDashboard(keyName, "hold", action, "Test")
  end
end

M.testFireDoubleTapTimer = function(keyName)
  local timer = state.doubleTapTimers[keyName]
  if not timer then return end
  timer:stop()
  state.doubleTapTimers[keyName] = nil
  local action = resolveKeyAction(keyName, "tap")
  executeAction(action, keyName, "tap")
  pushEventToDashboard(keyName, "tap", action, "Test")
end
M.currentProfile = currentProfile
M.rebuildBundleMaps = rebuildBundleMaps
M.stopMouseTimer = stopMouseTimer
M._executeAction = executeAction
M._setDeviceConnected = setDeviceConnected
M._clearInputState = clearInputState
M._onSessionLock = onSessionLock

return M
