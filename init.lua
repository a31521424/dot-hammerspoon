-- Keep Hammerspoon's switcher visible over full-screen windows without adding
-- another Dock icon.
hs.dockicon.hide()

-- Enable AppleScript and local IPC for health checks and troubleshooting.
hs.allowAppleScript(true)
require("hs.ipc")

-- Keep this global so Hammerspoon does not garbage-collect the switcher,
-- window filter, or hotkeys.
WindowSwitcher = require("window_switcher").start({
  -- Match Windows-style Alt-Tab: minimized windows are valid targets, while
  -- Cmd-H hidden applications stay out of the list.
  includeMinimized = true,
  includeHidden = false,

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
-- this repository; use voice_input_secret.lua or
-- HAMMERSPOON_VOICE_DOUBAO_API_KEY.
-- Recall words live in ~/.hammerspoon/voice_hotwords.lua
-- (copy from voice_hotwords.lua.example). Reload Hammerspoon after edits.
local voiceSecret = {}
pcall(function()
  voiceSecret = require("voice_input_secret") or {}
end)
VoiceInput = require("voice_input").start({
  apiKey = voiceSecret.apiKey or os.getenv("HAMMERSPOON_VOICE_DOUBAO_API_KEY"),
  resourceID = "volc.seedasr.auc",
  streamResourceID = "volc.seedasr.sauc.duration",
})
