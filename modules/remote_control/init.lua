-- Remote control mapping and management engine for Hammerspoon.
-- Supports Xiaomi Bluetooth Remote 2 Pro and other Bluetooth/USB remotes.
-- Features:
--   - Device isolation via macOS hidutil
--   - Tap / Hold / Double-click state machine
--   - Per-App profiles (Terminal/Termux, Web Browser, Global)
--   - Native integration with VoiceInput (streaming Doubao ASR via F18)
--   - Native integration with WindowSwitcher (vertical Alt-Tab)
--   - Persistent Control Panel (Dashboard) via hs.webview

local M = {}

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

-- Default transit key mappings (Virtual F13-F20 exclusively mapped from remote via hidutil/IOHID)
-- Standard keyboard keys (F1-F12) MUST NEVER be placed here to prevent hijacking user keyboard!
local TRANSIT_KEY_MAP = {
  [105] = "up",          -- F13
  [107] = "down",        -- F14
  [113] = "left",        -- F15
  [106] = "right",       -- F16
  [64]  = "ok",          -- F17
  [79]  = "voice",       -- F18 (Dedicated voice input key via hidutil / IOHID)
  [80]  = "back",        -- F19 (Back key via hidutil / IOHID)
  [90]  = "menu",        -- F20 (Window switcher via hidutil)
}

local TERMINAL_BUNDLES = {
  ["com.mitchellh.ghostty"] = true,
  ["com.googlecode.iterm2"] = true,
  ["com.apple.Terminal"] = true,
  ["io.alacritty"] = true,
  ["net.kovidgoyal.kitty"] = true,
  ["com.github.wez.wezterm"] = true,
  ["dev.warp.Warp-GDK"] = true,
}

local BROWSER_BUNDLES = {
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
  dashboard = nil,
  dashboardUserContent = nil,
  isDashboardVisible = false,
  mouseMode = false,
  mouseTimer = nil,
  activeKeys = {},
  keyTimers = {},
  doubleTapTimers = {},
  pendingDoubleTap = {},
  recentLogs = {},
  lastFocusedTerminal = nil,
  lastFocusedBrowser = nil,
}

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
  if bid and TERMINAL_BUNDLES[bid] then
    state.lastFocusedTerminal = app
  elseif bid and BROWSER_BUNDLES[bid] then
    state.lastFocusedBrowser = app
  end
end

local function currentProfile()
  local app = hs.application.frontmostApplication()
  local bid = app and app:bundleID()
  if bid and TERMINAL_BUNDLES[bid] then
    return "terminal", app:name() or bid
  elseif bid and BROWSER_BUNDLES[bid] then
    return "browser", app:name() or bid
  end
  return "global", app and app:name() or "System"
end

-- Device isolation via hidutil
local function applyHidutil(vendorID, productID)
  vendorID = vendorID or (state.config.device and state.config.device.vendorID) or 10007
  productID = productID or (state.config.device and state.config.device.productID) or 12984

  if vendorID == 0 or productID == 0 then
    log.w("Invalid vendorID/productID, skipping hidutil setup")
    return false
  end

  -- Remap physical remote usages to transit virtual keys (F13-F24)
  local mappings = {
    -- Direction ring: Up, Down, Left, Right -> F13, F14, F15, F16
    { HIDKeyboardModifierMappingSrc = 0x700000052, HIDKeyboardModifierMappingDst = 0x700000068 },
    { HIDKeyboardModifierMappingSrc = 0x700000051, HIDKeyboardModifierMappingDst = 0x700000069 },
    { HIDKeyboardModifierMappingSrc = 0x700000050, HIDKeyboardModifierMappingDst = 0x70000006A },
    { HIDKeyboardModifierMappingSrc = 0x70000004F, HIDKeyboardModifierMappingDst = 0x70000006B },
    -- OK (Enter) -> F17
    { HIDKeyboardModifierMappingSrc = 0x700000028, HIDKeyboardModifierMappingDst = 0x70000006C },
    -- Voice key (0x3E / F5 in Xiaomi remote report) -> F18
    { HIDKeyboardModifierMappingSrc = 0x70000003E, HIDKeyboardModifierMappingDst = 0x70000006D },
    -- Menu (0x65) -> F20
    { HIDKeyboardModifierMappingSrc = 0x700000065, HIDKeyboardModifierMappingDst = 0x70000006F },
    -- TV (0x35) -> F21
    { HIDKeyboardModifierMappingSrc = 0x700000035, HIDKeyboardModifierMappingDst = 0x700000070 },
    -- Volume Up (0x80) -> F22 (isolate from macOS default volume control)
    { HIDKeyboardModifierMappingSrc = 0x700000080, HIDKeyboardModifierMappingDst = 0x700000071 },
    -- Volume Down (0x81) -> F23 (isolate from macOS default volume control)
    { HIDKeyboardModifierMappingSrc = 0x700000081, HIDKeyboardModifierMappingDst = 0x700000072 },
    -- Home (0x4A) -> F23 (isolate from macOS default Home)
    { HIDKeyboardModifierMappingSrc = 0x70000004A, HIDKeyboardModifierMappingDst = 0x700000072 },
    -- Power (0x66) -> F24 (isolate from macOS default sleep)
    { HIDKeyboardModifierMappingSrc = 0x700000066, HIDKeyboardModifierMappingDst = 0x700000073 },
    -- Consumer page safety nets (if emitted by certain firmware revisions)
    { HIDKeyboardModifierMappingSrc = 0xC000000E9, HIDKeyboardModifierMappingDst = 0x700000071 },
    { HIDKeyboardModifierMappingSrc = 0xC000000EA, HIDKeyboardModifierMappingDst = 0x700000072 },
    { HIDKeyboardModifierMappingSrc = 0xC00000030, HIDKeyboardModifierMappingDst = 0x700000073 },
    { HIDKeyboardModifierMappingSrc = 0xC00000223, HIDKeyboardModifierMappingDst = 0x700000072 },
  }

  local payload = hs.json.encode({ UserKeyMapping = mappings })
  local cmd = string.format("hidutil property --matching '{\"VendorID\":%d,\"ProductID\":%d}' --set '%s'",
    vendorID, productID, payload)
  log.i("Applying hidutil mapping for device VID=" .. vendorID .. " PID=" .. productID)
  local out, status = hs.execute(cmd)
  return status == true
end

local function resetHidutil()
  log.i("Clearing all hidutil user key mappings")
  hs.execute("hidutil property --set '{\"UserKeyMapping\":[]}'")
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

-- Action Dispatcher
local function executeAction(actionStr, keyName, eventType)
  if not actionStr or actionStr == "" then return end
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
    else
      -- Fallback to posting virtual F18 key
      local isDown = (eventType == "down")
      local evt = hs.eventtap.event.newKeyEvent(79, isDown)
      evt:post()
    end
    return
  end

  -- For other actions, fire on tap or hold (not on raw key up)
  if eventType == "up" then return end

  -- 2. Window Switcher (Alt-Tab)
  if actionStr == "action:window_switcher" then
    logToFile("Executing window_switcher via alt-tab keyStroke")
    hs.eventtap.keyStroke({ "alt" }, "tab", 10000)
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
    state.mouseMode = not state.mouseMode
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
      if BROWSER_BUNDLES[bid] then
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
    state.mouseMode = false
    if WindowSwitcher and WindowSwitcher.cancel then
      WindowSwitcher.cancel()
    end
    hs.alert.show("已重置遥控状态", 1)
    return
  end

  -- 7. Macro actions
  if actionStr == "macro:approve_agent" then
    hs.eventtap.keyStroke({}, "y", 10000)
    hs.timer.doAfter(0.04, function()
      hs.eventtap.keyStroke({}, "return", 10000)
    end)
    return
  end

  if actionStr == "macro:restart_dev_server" then
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

-- Mouse Mode handler (Direction ring moves pointer, OK is left click, Back is right click, Vol+/Vol- is scroll wheel)
local function handleMouseMovement(keyName)
  local pos = hs.mouse.absolutePosition()
  local speed = (state.config.settings and state.config.settings.mouseSpeed) or 15
  local dx, dy = 0, 0
  if keyName == "up" then dy = -speed
  elseif keyName == "down" then dy = speed
  elseif keyName == "left" then dx = -speed
  elseif keyName == "right" then dx = speed
  elseif keyName == "ok" then
    hs.eventtap.leftClick(pos)
    return true
  elseif keyName == "back" then
    hs.eventtap.rightClick(pos)
    return true
  elseif keyName == "volume_up" then
    hs.eventtap.scrollWheel({ 0, 4 }, {}, "line")
    return true
  elseif keyName == "volume_down" then
    hs.eventtap.scrollWheel({ 0, -4 }, {}, "line")
    return true
  end

  if dx ~= 0 or dy ~= 0 then
    hs.mouse.absolutePosition({ x = pos.x + dx, y = pos.y + dy })
    return true
  end
  return false
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
    return false
  end

  updateAppTrack()
  local profileName, appTitle = currentProfile()
  logToFile("handleKeyEvent: keyName=%s keyCode=%s isDown=%s isRepeat=%s profile=%s app=%s",
    keyName, tostring(keyCode), tostring(isDown), tostring(isRepeat), profileName, appTitle or "System")

  -- Mouse mode interception
  if state.mouseMode and keyName ~= "power" and keyName ~= "voice" then
    if isDown then
      handleMouseMovement(keyName)
      local actionDesc = (keyName:find("volume") and "scroll") or "move_pointer"
      pushEventToDashboard(keyName, "mouse", actionDesc, appTitle)
    end
    return true
  end

  local holdMs = (state.config.settings and state.config.settings.holdThresholdMs) or 350
  local doubleIntervalMs = (state.config.settings and state.config.settings.doubleClickIntervalMs) or 250

  if isDown then
    -- If key is already marked active, this is a hardware repeat packet while held.
    -- Do not reset the timer; keep counting towards hold threshold!
    if isRepeat or state.activeKeys[keyName] then
      return true
    end

    state.activeKeys[keyName] = true

    -- Immediate visual feedback on KeyDown in Dashboard
    if keyName ~= "voice" then
      pushEventToDashboard(keyName, "down", resolveKeyAction(keyName, "tap") or "--", appTitle)
    end

    -- Special handling for voice: Start immediately on KeyDown
    if keyName == "voice" then
      executeAction("action:voice_input", keyName, "down")
      pushEventToDashboard(keyName, "down", "action:voice_input", appTitle)
      return true
    end

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
    state.keyTimers[keyName] = hs.timer.doAfter(holdMs / 1000, function()
      state.keyTimers[keyName] = nil
      state.pendingDoubleTap[keyName] = nil
      if state.activeKeys[keyName] then
        local action = resolveKeyAction(keyName, "hold")
        executeAction(action, keyName, "hold")
        pushEventToDashboard(keyName, "hold", action, appTitle)
      end
    end)
    return true
  else
    -- KeyUp
    state.activeKeys[keyName] = nil

    -- Special handling for voice: Stop immediately on KeyUp
    if keyName == "voice" then
      executeAction("action:voice_input", keyName, "up")
      pushEventToDashboard(keyName, "up", "action:voice_input", appTitle)
      return true
    end

    -- If hold timer was still pending, this was a short press (Tap or Double Tap)
    if state.keyTimers[keyName] ~= nil then
      state.keyTimers[keyName]:stop()
      state.keyTimers[keyName] = nil

      -- Was this the second tap of a double-tap?
      if state.pendingDoubleTap[keyName] then
        state.pendingDoubleTap[keyName] = nil
        local doubleAction = resolveKeyAction(keyName, "double_tap")
        if doubleAction then
          executeAction(doubleAction, keyName, "double_tap")
          pushEventToDashboard(keyName, "double_tap", doubleAction, appTitle)
          return true
        end
      end

      -- Check if current profile has double_tap configured for this key
      local doubleTapAction = resolveKeyAction(keyName, "double_tap")
      if doubleTapAction then
        -- Delay execution to detect potential second tap
        state.doubleTapTimers[keyName] = hs.timer.doAfter(doubleIntervalMs / 1000, function()
          state.doubleTapTimers[keyName] = nil
          local action = resolveKeyAction(keyName, "tap")
          executeAction(action, keyName, "tap")
          pushEventToDashboard(keyName, "tap", action, appTitle)
        end)
      else
        -- No double-tap configured: fire tap immediately with zero delay
        local action = resolveKeyAction(keyName, "tap")
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
    local eventType = event:getType()
    local keyCode = event:getKeyCode()
    local isDown = (eventType == hs.eventtap.event.types.keyDown)
    local isRepeat = event:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) == 1

    -- If remote_hid_listener is active, it authoritative handles all remote buttons
    -- directly via IOHID (VID/PID isolated). eventtap only needs to consume isolated
    -- virtual transit keys (F13-F20) so they don't leak into foreground apps.
    if state.hidTask and state.hidTask:isRunning() then
      if TRANSIT_KEY_MAP[keyCode] then
        return true -- eat transit key
      end
      return false -- pass through Mac physical keyboard keys completely untouched
    end

    -- Fallback when listener binary is not running
    local eaten = handleKeyEvent(keyCode, isDown, isRepeat)
    return eaten
  end)
  state.eventtap:start()
  log.i("RemoteControl eventtap started")
end

-- IOHID helper for keys that hidutil cannot remap (e.g. Back button 0xF1)
local function startHidListener()
  if state.hidTask and state.hidTask:isRunning() then
    state.hidTask:terminate()
    state.hidTask = nil
  end

  -- Terminate any lingering instances from past sessions/reloads
  hs.execute("pkill -f 'remote_hid_listener|modules/remote_control/listener'")

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
  state.hidTask = hs.task.new(helperBin, function(code, stdout, stderr)
    logToFile("remote_hid_listener exited code=%d", code or -1)
  end, function(task, stdout, stderr)
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
              logToFile("Remote control connected via IOHID, applying hidutil mapping...")
              if state.config.device and state.config.device.autoApplyHidutil then
                applyHidutil(vid, pid)
              end
              M.refreshDashboardData()
            elseif event.event == "device_removed" then
              logToFile("Remote control disconnected")
              for _, t in pairs(state.keyTimers) do t:stop() end
              state.keyTimers = {}
              for _, t in pairs(state.doubleTapTimers) do t:stop() end
              state.doubleTapTimers = {}
              state.pendingDoubleTap = {}
              state.activeKeys = {}
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

  if state.hidTask:start() then
    log.i("remote_hid_listener started successfully for Back button (0xF1)")
  else
    log.ef("Failed to start remote_hid_listener task")
  end
end

local function stopHidListener()
  if state.hidTask and state.hidTask:isRunning() then
    state.hidTask:terminate()
    state.hidTask = nil
  end
  hs.execute("pkill -f 'remote_hid_listener|modules/remote_control/listener'")
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
        state.config.device = payload
        saveConfig(state.config)
        local ok = applyHidutil(payload.vendorID, payload.productID)
        startHidListener()
        hs.alert.show(ok and "已重新配置 hidutil 隔离与按键监听" or "hidutil 配置失败，请检查 VID/PID", 2)
      end
    elseif action == "reset_hidutil" then
      resetHidutil()
      hs.alert.show("已重置清空 hidutil 映射", 1.5)
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

function M.start(options)
  options = options or {}
  state.config = loadConfig()

  setupEventTap()

  -- Auto apply hidutil if configured
  if state.config.device and state.config.device.autoApplyHidutil then
    local vid = state.config.device.vendorID
    local pid = state.config.device.productID
    if vid and pid and vid > 0 and pid > 0 then
      applyHidutil(vid, pid)
    end
  end

  -- Start IOHID listener for Back button (0xF1) and non-standard HID keys
  startHidListener()

  -- Global shortcut to summon dashboard (Option + Shift + R)
  state.hotkey = hs.hotkey.bind({ "alt", "shift" }, "r", function()
    M.toggleDashboard()
  end)

  -- Cleanup on Hammerspoon reload / exit
  local prevShutdown = hs.shutdownCallback
  hs.shutdownCallback = function()
    stopHidListener()
    for _, t in pairs(state.keyTimers) do t:stop() end
    state.keyTimers = {}
    for _, t in pairs(state.doubleTapTimers) do t:stop() end
    state.doubleTapTimers = {}
    state.pendingDoubleTap = {}
    state.activeKeys = {}
    if state.config.device and state.config.device.autoApplyHidutil then
      resetHidutil()
    end
    if type(prevShutdown) == "function" then
      prevShutdown()
    end
  end

  log.i("RemoteControl module started successfully")
  return M
end

function M.stop()
  stopHidListener()
  if state.eventtap then
    state.eventtap:stop()
    state.eventtap = nil
  end
  if state.hotkey then
    state.hotkey:delete()
    state.hotkey = nil
  end
  if state.dashboard then
    state.dashboard:delete()
    state.dashboard = nil
  end
  for _, t in pairs(state.keyTimers) do t:stop() end
  state.keyTimers = {}
  for _, t in pairs(state.doubleTapTimers) do t:stop() end
  state.doubleTapTimers = {}
  state.pendingDoubleTap = {}
  state.activeKeys = {}
  state.mouseMode = false
  resetHidutil()
  log.i("RemoteControl module stopped")
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
  if timer then
    state.keyTimers[keyName] = nil
    state.pendingDoubleTap[keyName] = nil
    if state.activeKeys[keyName] then
      local action = resolveKeyAction(keyName, "hold")
      executeAction(action, keyName, "hold")
      pushEventToDashboard(keyName, "hold", action, "Test")
    end
  end
end
M.testFireDoubleTapTimer = function(keyName)
  local timer = state.doubleTapTimers[keyName]
  if timer then
    state.doubleTapTimers[keyName] = nil
    local action = resolveKeyAction(keyName, "tap")
    executeAction(action, keyName, "tap")
    pushEventToDashboard(keyName, "tap", action, "Test")
  end
end

return M
