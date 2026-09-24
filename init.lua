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

-- Keep this global so Hammerspoon does not garbage-collect the switcher,
-- window filter, or hotkeys.
WindowSwitcher = require("modules.window_switcher").start({
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
  -- state machine keeps repeated Option-Tab presses fast and reliable.
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

-- Voice input: hold Option + W to transcribe, release to stop.
-- A preview shows the full transcript; the complete text is pasted
-- at the caret after recognition finishes. Keep the API key out of
-- this repository; use modules/voice_input/secret.lua (or voice_input_secret.lua) or
-- HAMMERSPOON_VOICE_DOUBAO_API_KEY.
-- Recall words live in modules/voice_input/hotwords.lua
-- (copy from hotwords.lua.example). Reload Hammerspoon after edits.
local voiceSecret = {}
pcall(function()
  voiceSecret = require("modules.voice_input.secret") or {}
end)
if not voiceSecret.apiKey then
  pcall(function()
    voiceSecret = require("voice_input_secret") or {}
  end)
end
VoiceInput = require("modules.voice_input").start({
  apiKey = voiceSecret.apiKey or os.getenv("HAMMERSPOON_VOICE_DOUBAO_API_KEY"),
  resourceID = "volc.seedasr.auc",
  streamResourceID = "volc.seedasr.sauc.duration",
})

-- Remote Control Engine: maps Bluetooth/HID remote hardware keys to Web development
-- actions (Termux/Terminal AI agent approvals, browser live reloads, mouse mode),
-- integrates directly with WindowSwitcher and VoiceInput, and provides
-- a persistent Control Panel (Dashboard).
RemoteControl = require("modules.remote_control").start()


