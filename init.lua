-- Keep Hammerspoon's switcher visible over full-screen windows without adding
-- another Dock icon.
hs.dockicon.hide()

-- IPC 供 hs -c 测试与排障；不开启 AppleScript 自动化入口。
require("hs.ipc")

-- Configure package.path to discover modular packages under ~/.hammerspoon/modules/
local configDir = hs.configdir or ((os.getenv("HOME") or "") .. "/.hammerspoon")
package.path = configDir .. "/modules/?.lua;"
            .. configDir .. "/modules/?/init.lua;"
            .. package.path

-- 按需启用插件模块（不需要的模块设为 false；定向安装未拉取对应目录时也会自动跳过）
local ENABLED_MODULES = {
  window_switcher = true,  -- 1. 垂直窗口切换器 (modules/window_switcher)
  remote_control  = false, -- 2. 蓝牙遥控器控制引擎 (modules/remote_control)
  voice_input     = true,  -- 3. 流式语音输入 (modules/voice_input)
  input_target    = false, -- 4. 跨模块焦点一致性保护 (modules/input_target.lua)
}

local function hasModule(relPath)
  return hs.fs.attributes(configDir .. "/" .. relPath, "mode") == "file"
end

-- 1. Window Switcher: vertical Command-Tab switcher ordered by WindowServer MRU.
-- Keep this global so Hammerspoon does not garbage-collect the switcher,
-- window filter, or hotkeys.
if ENABLED_MODULES.window_switcher and hasModule("modules/window_switcher/init.lua") then
  WindowSwitcher = require("modules.window_switcher").start({
    nativeCommandTab = true,
    -- Match Windows-style Alt-Tab: minimized windows are valid targets, while
    -- Cmd-H hidden applications stay out of the list.
    includeMinimized = true,
    includeHidden = false,
    -- Keep Alt-Tab on the pointer's screen when the switching session starts.
    -- Set false to include windows from all displays again.
    currentScreenOnly = true,

    -- Allow substantive untitled windows (such as mobile mirroring/remote control windows).
    -- com.vivo.pcsuite.vivoScreen is included by default.
    allowUntitledApps = {
      ["com.vivo.pcsuite.vivoScreen"] = true,
    },

    -- Built-in switcher UI: title-only, without window previews. Its native
    -- state machine keeps repeated Command-Tab presses fast and reliable.
    ui = {
      showTitles = true,
      showThumbnails = false,
      showSelectedThumbnail = false,
      showSelectedTitle = false,
      showExtraKeys = false,
      thumbnailSize = 100,
      textSize = 13,
      listWidthRatio = 0.58,
      listMinWidth = 620,
      listMaxWidth = 860,
      listRowHeight = 32,
      listIconSize = 18,
      listPadding = 8,
      backgroundColor = {
        red = 0.025,
        green = 0.03,
        blue = 0.04,
        alpha = 0.72,
      },
      titleBackgroundColor = {
        red = 0.04,
        green = 0.045,
        blue = 0.055,
        alpha = 0,
      },
      highlightColor = {
        red = 0.16,
        green = 0.40,
        blue = 0.80,
        alpha = 0.70,
      },
    },

    ignored = {
      -- Edit these maps to exclude complete applications. Bundle IDs are more
      -- stable than display names and are preferred when available.
      bundleIDs = {
        ["org.hammerspoon.Hammerspoon"] = true,
        ["com.lwouis.alt-tab-macos"] = true,
      },

      appNames = {
        -- ["Application Name"] = true,
      },

      -- Lua patterns can be global ("*") or scoped to an app's bundle ID/name.
      titlePatterns = {
        ["*"] = {
          -- "^Window title to ignore$",
        },
        -- ["com.example.app"] = { "^Helper", "^Preferences$" },
      },
    },
  })
elseif WindowSwitcher and WindowSwitcher.stop then
  WindowSwitcher:stop()
  WindowSwitcher = nil
end

-- 3. Voice input: hold Option + W to transcribe, release to stop.
-- A preview shows the full transcript; the complete text is pasted
-- at the caret after recognition finishes. Keep the API key out of
-- this repository; use modules/voice_input/secret.lua or
-- HAMMERSPOON_VOICE_DOUBAO_API_KEY.
-- Recall words live in modules/voice_input/hotwords.lua
-- (copy from hotwords.lua.example). Reload Hammerspoon after edits.
if ENABLED_MODULES.voice_input and hasModule("modules/voice_input/init.lua") then
  local voiceSecret = {}
  pcall(function()
    voiceSecret = require("modules.voice_input.secret") or {}
  end)
  VoiceInput = require("modules.voice_input").start({
    apiKey = voiceSecret.apiKey or os.getenv("HAMMERSPOON_VOICE_DOUBAO_API_KEY"),
    resourceID = "volc.seedasr.auc",
    streamResourceID = "volc.seedasr.sauc.duration",
    guardInputTarget = ENABLED_MODULES.input_target and hasModule("modules/input_target.lua"),
  })
elseif VoiceInput then
  pcall(function() require("modules.voice_input").stop() end)
  VoiceInput = nil
end

-- 2. Remote Control Engine: maps Bluetooth/HID remote hardware keys to actions,
-- integrates with WindowSwitcher and VoiceInput (when enabled), and provides
-- a persistent Control Panel (Dashboard).
if ENABLED_MODULES.remote_control and hasModule("modules/remote_control/init.lua") then
  RemoteControl = require("modules.remote_control").start()
elseif RemoteControl and RemoteControl.stop then
  RemoteControl.stop()
  RemoteControl = nil
end


