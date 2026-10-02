-- Unit & Integration Tests for Remote Control Engine (remote_control.lua)
-- Run via: hs -c 'return dofile(hs.configdir .. "/tests/remote_control_test.lua")'

local root = (hs and hs.configdir) or "."
package.loaded["modules.remote_control"] = nil
package.loaded["remote_control"] = nil
local ok, RC = pcall(require, "modules.remote_control")
if not ok then RC = require("remote_control") end
local state = RC._state
state.config = hs.json.read(root .. "/modules/remote_control/config.json.example")
-- Tests use a deterministic input target and never depend on desktop focus.
local InputTarget = require("modules.input_target")
local originalCapture = InputTarget.capture
local testTarget = { bundleID = "com.googlecode.iterm2", pid = 1, windowID = 1, element = "pane-1", navigationEpoch = 0 }
InputTarget.capture = function() return testTarget end
state.config.settings.targetBundleID = nil
state._testBundleID = "com.googlecode.iterm2"
local originalDoAfter, originalDoEvery = hs.timer.doAfter, hs.timer.doEvery
local originalAlertShow = hs.alert.show
local visibleAlertsBefore = #hs.alert._visibleAlerts
local testAlerts = {}
-- Simulated timers cannot dismiss real drawings; keep test alerts in memory.
hs.alert.show = function(message)
  testAlerts[#testAlerts + 1] = message
  return "test-alert-" .. #testAlerts
end
local scheduled = {}
local function fakeTimer(delay, callback)
  local t = { delay = delay, callback = callback, stopped = false }
  function t:stop() self.stopped = true end
  scheduled[#scheduled + 1] = t
  return t
end
hs.timer.doAfter, hs.timer.doEvery = fakeTimer, fakeTimer

local function assertEq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("ASSERTION FAILED: %s (expected: %s, got: %s)",
      msg or "", tostring(expected), tostring(actual)), 2)
  end
end

local function assertTrue(condition, msg)
  if not condition then
    error(string.format("ASSERTION FAILED: %s", msg or "expected true"), 2)
  end
end

local function assertFalse(condition, msg)
  if condition then
    error(string.format("ASSERTION FAILED: %s", msg or "expected false"), 2)
  end
end

print("=== Running Remote Control Unit Tests ===")

-- Test 1: Transit Key Map Keyboard Safety
-- Ensure NO standard keyboard keycodes (F1-F12, Backspace, Enter, Arrows) exist in TRANSIT_KEY_MAP
print("[Test 1] Native Keyboard Isolation check...")
local unsafeCodes = {
  [111] = "F12",
  [103] = "F11",
  [109] = "F10",
  [101] = "F9",
  [100] = "F8",
  [98]  = "F7",
  [97]  = "F6",
  [96]  = "F5",
  [118] = "F4",
  [99]  = "F3",
  [120] = "F2",
  [122] = "F1",
  [36]  = "Return",
  [51]  = "Backspace",
  [53]  = "Escape",
}
for code, name in pairs(unsafeCodes) do
  local mapped = RC.TRANSIT_KEY_MAP and RC.TRANSIT_KEY_MAP[code]
  assertFalse(mapped, "Standard keyboard key " .. name .. " (keycode " .. code .. ") must NOT be in TRANSIT_KEY_MAP!")
end
-- Identity comes from IOHID; only inert F20 is swallowed as an OS transit key.
assertEq(RC.TRANSIT_KEY_MAP[90], "isolated_remote", "F20 must be isolation-only")
assertFalse(RC.TRANSIT_KEY_MAP[107], "F14 must not be used as a transit key")
assertFalse(RC.TRANSIT_KEY_MAP[113], "F15 must not be used as a transit key")
print("  ✓ Native Mac keyboard keycodes are 100% free from hijacking.")

-- Test 2: Key Stroke Parser and Aliases
print("[Test 2] Key Stroke Parser & KEY_ALIASES check...")
local parseKeyStroke = RC.parseKeyStroke
local function checkParse(input, expectedMods, expectedKey)
  local mods, key = parseKeyStroke(input)
  assertEq(key, expectedKey, "Key alias failed for: " .. input)
  assertEq(#mods, #expectedMods, "Mods count mismatch for: " .. input)
  for i, m in ipairs(expectedMods) do
    assertEq(mods[i], m, "Mod mismatch at " .. i .. " for: " .. input)
  end
end

checkParse("key:ctrl+c", { "ctrl" }, "c")
checkParse("key:shift+cmd+r", { "shift", "cmd" }, "r")
checkParse("key:page_up", {}, "pageup")
checkParse("key:page_down", {}, "pagedown")
checkParse("key:enter", {}, "return")
checkParse("key:return_key", {}, "return")
checkParse("key:backspace", {}, "delete")
checkParse("key:esc", {}, "escape")
print("  ✓ Key aliases properly normalized (page_up -> pageup, enter -> return, etc.)")

-- Test 3: Hardware HID Usage Matrix Decoding
print("[Test 3] Hardware HID Usage Decoding check...")
local expectedUsages = {
  [0x52] = "up",
  [0x51] = "down",
  [0x50] = "left",
  [0x4F] = "right",
  [0x28] = "ok",
  [0x3E] = "voice",
  [0xF1] = "back",
  [0x65] = "menu",
  [0x35] = "tv",
  [0x80] = "volume_up",
  [0x81] = "volume_down",
  [0x4A] = "home",
  [0x66] = "power",
}
for usage, expectedName in pairs(expectedUsages) do
  local decoded = RC.decodeHidUsage(0x07, usage)
  assertEq(decoded, expectedName, string.format("Usage 0x%02X failed to decode", usage))
end
-- Consumer page usages
assertEq(RC.decodeHidUsage(0x0C, 0x0224), "back", "Consumer AC Back 0x0224 must decode to back")
assertEq(RC.decodeHidUsage(0x0C, 0x0223), "home", "Consumer AC Home 0x0223 must decode to home")
assertEq(RC.decodeHidUsage(0x0C, 0xE9), "volume_up", "Consumer Volume Up 0xE9 must decode to volume_up")
assertEq(RC.decodeHidUsage(0x0C, 0xEA), "volume_down", "Consumer Volume Down 0xEA must decode to volume_down")
assertEq(RC.decodeHidUsage(0x0C, 0x30), "power", "Consumer Power 0x30 must decode to power")
print("  ✓ All 13 physical and consumer remote usages correctly map to internal keyNames.")

-- Test 4: Profile & Key Action Resolution
print("[Test 4] Per-App Profile Action Resolution check...")
local resolveKeyAction = RC.resolveKeyAction

-- Test with profile override
local actionOKTap = resolveKeyAction("ok", "tap", "terminal")
assertEq(actionOKTap, "key:return", "Terminal OK tap should be plain Enter")

local actionBackTap = resolveKeyAction("back", "tap", "terminal")
assertEq(actionBackTap, "key:delete", "Terminal Back tap should delete")

local actionBackHold = resolveKeyAction("back", "hold", "terminal")
assertEq(actionBackHold, "key:delete", "Terminal Back hold should repeat deletion")

local actionVolUp = resolveKeyAction("volume_up", "tap", "terminal")
assertEq(actionVolUp, "key:pageup", "Terminal Vol+ should send PageUp")

local actionBrowserVolUp = resolveKeyAction("volume_up", "tap", "browser")
assertEq(actionBrowserVolUp, "key:pageup", "Browser Vol+ mapping should be consistent")

local actionGlobalVolUp = resolveKeyAction("volume_up", "tap", "global")
assertEq(actionGlobalVolUp, "key:pageup", "Global Vol+ mapping should be consistent")

local actionTVGlobal = resolveKeyAction("tv", "tap", "global")
assertEq(actionTVGlobal, "action:toggle_review", "TV should toggle output review")

local actionTVGlobalHold = resolveKeyAction("tv", "hold", "global")
assertEq(actionTVGlobalHold, "action:none", "TV hold should do nothing")

local actionHomeGlobal = resolveKeyAction("home", "tap", "global")
assertEq(actionHomeGlobal, "action:focus_iterm", "Home should focus iTerm2")

local actionPowerTap = resolveKeyAction("power", "tap", "global")
assertEq(actionPowerTap, "action:none", "Power tap should do nothing")

local actionPowerHold = resolveKeyAction("power", "hold", "global")
assertEq(actionPowerHold, "action:toggle_dashboard", "Power hold should open configuration")
print("  ✓ All profiles (terminal, browser, global) resolve actions correctly.")

-- Test 5: State Machine Repeat De-bounce & Hold Logic
print("[Test 5] State Machine: Tap, Hold & Hardware Repeat Packet Handling...")
local executed = {}
local function mockExecute(action, keyName, triggerType)
  table.insert(executed, { action = action, key = keyName, type = triggerType })
end

-- Hook executeAction for testing
RC._mockExecuteAction = mockExecute

-- 5a: Tap test (KeyDown then KeyUp quickly)
executed = {}
RC.testTriggerKey("tv", true, false) -- KeyDown
assertTrue(state.activeKeys["tv"] == true, "Key tv should be active on KeyDown")
assertTrue(state.keyTimers["tv"] ~= nil, "Hold timer should be active")
RC.testTriggerKey("tv", false, false) -- KeyUp within holdMs
assertFalse(state.activeKeys["tv"], "Key tv should be inactive after KeyUp")
assertTrue(state.keyTimers["tv"] == nil, "Hold timer should be cleared on tap")
assertEq(#executed, 1, "Exactly one tap action should have executed")
assertEq(executed[1].type, "tap", "Executed action should be tap")
local expectedAction = RC.resolveKeyAction("tv", "tap")
assertEq(executed[1].action, expectedAction, "TV tap action should match current profile")
print("  ✓ Short tap executed successfully.")

-- 5b: Hardware Hold Repeat Packet Test
-- When holding, hardware sends repeated KeyDown packets. It must NOT reset the hold timer!
executed = {}
RC.testTriggerKey("power", true, false) -- First KeyDown
local initialTimer = state.keyTimers["power"]
assertTrue(initialTimer ~= nil, "Power hold timer should be created")

-- Hardware reports another KeyDown 50ms later while still held
RC.testTriggerKey("power", true, false)
assertEq(state.keyTimers["power"], initialTimer, "Hold timer MUST NOT be replaced by repeated KeyDown packets!")

-- Simulate timer expiration (manually trigger timer callback)
RC.testFireTimer("power")
assertEq(#executed, 1, "Hold action should execute when timer fires")
assertEq(executed[1].type, "hold", "Action type should be hold")
local expectedPowerHold = RC.resolveKeyAction("power", "hold")
assertEq(executed[1].action, expectedPowerHold, "Power hold action should match profile")

-- Now release (KeyUp)
RC.testTriggerKey("power", false, false)
assertEq(#executed, 1, "KeyUp after hold MUST NOT fire a tap action!")
print("  ✓ Hardware repeat packets successfully debounced, hold executed cleanly.")

-- 5c: Voice Key Immediate Execution (Hold to talk)
executed = {}
RC.testTriggerKey("voice", true, false)
assertEq(#executed, 1, "Voice key should trigger immediately on down")
assertEq(executed[1].type, "down", "Voice down event type mismatch")
assertEq(executed[1].action, "action:voice_input", "Voice action mismatch")

RC.testTriggerKey("voice", false, false)
assertEq(#executed, 2, "Voice key should trigger immediately on up")
assertEq(executed[2].type, "up", "Voice up event type mismatch")
assertEq(executed[2].action, "action:voice_input", "Voice action mismatch")
print("  ✓ Voice hold-to-talk stream started on down and stopped on up.")

-- 5d: Double-Tap detection test (when double_tap is configured)
executed = {}
local savedHome = state.config.profiles.global.keys.home
state.config.profiles.global.keys.home = { tap = "action:mission_control", double_tap = "action:show_desktop" }
state._testBundleID = "com.test.global"
-- First tap
RC.testTriggerKey("home", true, false)
RC.testTriggerKey("home", false, false)
assertTrue(state.doubleTapTimers["home"] ~= nil, "Double-tap timer should be waiting for second tap")
assertEq(#executed, 0, "No tap action should execute immediately when double_tap is configured")

-- Second tap arrives within window
RC.testTriggerKey("home", true, false)
assertTrue(state.pendingDoubleTap["home"] == true, "Second Down should mark pendingDoubleTap")
RC.testTriggerKey("home", false, false)
assertEq(#executed, 1, "Double-tap action should execute on second KeyUp")
assertEq(executed[1].type, "double_tap", "Action type should be double_tap")
assertEq(executed[1].action, "action:show_desktop", "Double-tap action should resolve to show_desktop")
print("  ✓ Double-tap sequence successfully detected and dispatched.")

-- 5e: Double-Tap timeout fallback to Single Tap
-- 不得在真实桌面触发 Mission Control；不得在清 mock 后 usleep
executed = {}
RC.testTriggerKey("home", true, false)
RC.testTriggerKey("home", false, false)
assertTrue(state.doubleTapTimers["home"] ~= nil, "Double-tap timer should be waiting")
RC.testFireDoubleTapTimer("home") -- Timer expires
assertEq(#executed, 1, "Single tap should execute when double-tap timer expires")
assertEq(executed[1].type, "tap", "Action type should be tap")
assertEq(executed[1].action, "action:mission_control", "Action should resolve to mission_control")
print("  ✓ Double-tap timeout correctly falls back to single tap.")

state.config.profiles.global.keys.home = savedHome
state._testBundleID = "com.googlecode.iterm2"

-- Test 6: Mouse Mode & Scroll Wheel
print("[Test 6] Mouse Mode: Pointer & Scroll Wheel check...")
state.mouseMode = true
local eatenVolUp = RC.testTriggerKey("volume_up", true, false)
assertTrue(eatenVolUp, "Mouse mode volume_up should be consumed")
local eatenVolUpRelease = RC.testTriggerKey("volume_up", false, false)
assertTrue(eatenVolUpRelease, "Mouse mode volume_up release should be consumed")
local eatenVolDown = RC.testTriggerKey("volume_down", true, false)
assertTrue(eatenVolDown, "Mouse mode volume_down should be consumed")
local eatenVolDownRelease = RC.testTriggerKey("volume_down", false, false)
assertTrue(eatenVolDownRelease, "Mouse mode volume_down release should be consumed")
if RC.stopMouseTimer then RC.stopMouseTimer() end
state.mouseMode = false
print("  ✓ Mouse mode scroll wheel integration verified.")

-- FIX-05: Test hidutil reset command string contains --matching VID/PID
local resetCmd = RC._hidutilResetCommand and RC._hidutilResetCommand(10007, 12984)
assertTrue(type(resetCmd) == "string", "reset command must be string")
assertTrue(resetCmd:find("--matching", 1, true) ~= nil, "reset command must contain --matching")
assertTrue(resetCmd:find('"VendorID":10007', 1, true) ~= nil, "reset command must match VendorID")
assertTrue(resetCmd:find('"ProductID":12984', 1, true) ~= nil, "reset command must match ProductID")
assertTrue(resetCmd:find('"UserKeyMapping":%[%]') ~= nil or resetCmd:find('"UserKeyMapping":[]', 1, true) ~= nil, "reset command must set empty UserKeyMapping")
print("  ✓ FIX-05: hidutil reset command correctly scoped with --matching VID/PID.")

-- FIX-03 / FIX-04 / FIX-09: HID table alignment and payload test
print("[Test 7] HID Mapping Table & Payload validation...")
local foundConsumerBack, foundBrightnessUp, foundBrightnessDown = false, false, false
for _, row in ipairs(RC.HIDUTIL_MAPPINGS or {}) do
  assertEq(row.dst, 0x70000006F, "Every isolated usage must map to F20")
  assertTrue(row.isolationOnly, "No OS transit key may dispatch a semantic button")
  if row.src == 0xC00000224 then foundConsumerBack = true end
  if row.src == 0xC0000006F then foundBrightnessUp = true end
  if row.src == 0xC00000070 then foundBrightnessDown = true end
end
assertTrue(foundConsumerBack, "Consumer Back must be isolated")
assertTrue(foundBrightnessUp and foundBrightnessDown, "Consumer brightness must be isolated")
assertTrue(RC.testTriggerKey(90, true, false), "F20 must be swallowed without dispatch")

local payload = RC._hidutilApplyPayload and RC._hidutilApplyPayload()
assertTrue(type(payload) == "string", "apply payload must be a string")
assertTrue(payload:find("HIDKeyboardModifierMappingSrc", 1, true) ~= nil, "payload must contain HIDKeyboardModifierMappingSrc")
assertTrue(payload:find("HIDKeyboardModifierMappingDst", 1, true) ~= nil, "payload must contain HIDKeyboardModifierMappingDst")
assertFalse(payload:find("isolationOnly", 1, true) ~= nil, "payload must NOT contain isolationOnly")
assertFalse(payload:find('"keycode"', 1, true) ~= nil, "payload must NOT contain keycode")
assertFalse(payload:find('"key"', 1, true) ~= nil, "payload must NOT contain key")

assertFalse(RC.listenerRunning(), "listenerRunning() must return false when hidTask is nil")
print("  ✓ F20 isolation, brightness usages, and payload validated.")

-- FIX-16: Session Lock swallowing & login window pass-through
print("[Test 8] Session Lock Key Suppression check...")
executed = {}
state.sessionLocked = true
local swallowedDown = RC.testTriggerKey("ok", true, false)
assertTrue(swallowedDown, "Down event for known key must be swallowed when locked")
local swallowedUp = RC.testTriggerKey("ok", false, false)
assertTrue(swallowedUp, "Up event for known key must be swallowed when locked")
assertEq(#executed, 0, "No actions may be executed while screen is locked")

-- When locked, unknown keys (like physical keyboard Return keycode 36) must pass through
local returnEaten = RC.testTriggerKey(36, true, false)
assertFalse(returnEaten, "Keycode 36 (Return) must NOT be swallowed when locked (login window pass-through)")
state.sessionLocked = false
print("  ✓ Remote keys strictly swallowed during lock; real keyboard passes through.")

-- FIX-02: Profile routing based on bundleIDs
print("[Test 9] Profile Routing with Custom bundleIDs check...")
state.config.profiles = state.config.profiles or {}
state.config.profiles.terminal = state.config.profiles.terminal or { keys = {} }
state.config.profiles.terminal.bundleIDs = { "com.example.customterm" }
state.config.profiles.browser = state.config.profiles.browser or { keys = {} }
state.config.profiles.browser.bundleIDs = { "com.example.custombrowser" }
RC.rebuildBundleMaps()

state._testBundleID = "com.example.customterm"
local profTerm = RC.currentProfile()
assertEq(profTerm, "terminal", "Custom terminal bundleID should route to terminal profile")

state._testBundleID = "com.example.custombrowser"
local profBrow = RC.currentProfile()
assertEq(profBrow, "browser", "Custom browser bundleID should route to browser profile")

state._testBundleID = "com.example.unknownapp"
local profGlobal = RC.currentProfile()
assertEq(profGlobal, "global", "Unknown bundleID should route to global profile")

-- Overlap test: terminal priority
state.config.profiles.terminal.bundleIDs = { "com.example.sharedapp" }
state.config.profiles.browser.bundleIDs = { "com.example.sharedapp" }
RC.rebuildBundleMaps()
state._testBundleID = "com.example.sharedapp"
local profShared = RC.currentProfile()
assertEq(profShared, "terminal", "Terminal profile must take precedence over browser for shared bundleID")

state._testBundleID = nil
print("  ✓ Custom bundleIDs routing and terminal precedence verified.")

-- FIX-12: Configurable voice key
print("[Test 10] Configurable Voice Key check...")
local savedVoiceCfg = state.config.profiles.global.keys.voice
state.config.profiles.global.keys.voice = { tap = "key:return" }
state._testBundleID = "com.test.global"
executed = {}
RC.testTriggerKey("voice", true, false)
assertEq(#executed, 0, "Remapped voice key should NOT trigger on down")
RC.testTriggerKey("voice", false, false)
assertEq(#executed, 1, "Remapped voice key should trigger tap on up")
assertEq(executed[1].type, "tap", "Action type should be tap")
assertEq(executed[1].action, "key:return", "Action should resolve to key:return")
state.config.profiles.global.keys.voice = savedVoiceCfg
state._testBundleID = nil
print("  ✓ Remapped voice key follows normal tap lifecycle.")

-- FIX-16: dangerousMacros flag
print("[Test 11] dangerousMacros flag check...")
local origKeyStroke = hs.eventtap.keyStroke
local strokes = {}
hs.eventtap.keyStroke = function(mods, key)
  table.insert(strokes, { mods = mods, key = key })
end

RC._mockExecuteAction = nil
state.config.settings = state.config.settings or {}

-- When dangerousMacros is false, macro:approve_agent and macro:restart_dev_server must be no-ops
state.config.settings.dangerousMacros = false
strokes = {}
RC._executeAction("macro:approve_agent", "ok", "tap")
assertEq(#strokes, 0, "macro:approve_agent must be no-op when dangerousMacros == false")

RC._executeAction("macro:restart_dev_server", "ok", "hold")
assertEq(#strokes, 0, "macro:restart_dev_server must be no-op when dangerousMacros == false")

-- When dangerousMacros is true (or default), macro:approve_agent executes
state.config.settings.dangerousMacros = true
strokes = {}
RC._executeAction("macro:approve_agent", "ok", "tap")
assertEq(#strokes, 1, "macro:approve_agent must execute when dangerousMacros == true")
assertEq(strokes[1].key, "y", "macro:approve_agent should press y")

local returnTimer = scheduled[#scheduled]
returnTimer.callback()
assertEq(#strokes, 2, "Approval macro timer must be tested while keystrokes are mocked")
assertEq(strokes[2].key, "return", "Approval macro should finish with Return")
hs.eventtap.keyStroke = origKeyStroke
RC._mockExecuteAction = mockExecute
print("  ✓ dangerousMacros flag properly suppresses agent approval and server restart macros.")

print("[Test 12] Workflow repeat, target guards, and long-press safety...")
state._testBundleID = "com.googlecode.iterm2"
for _, pair in ipairs({ { "menu", "key:delete", 0.35, 0.09 }, { "back", "key:delete", 0.35, 0.09 },
    { "volume_up", "key:pageup", 0.5, 0.25 }, { "volume_down", "key:pagedown", 0.5, 0.25 } }) do
  executed = {}
  RC.testTriggerKey(pair[1], true, false)
  assertEq(#executed, 1, "Delete/page key must execute on down")
  assertEq(executed[1].action, pair[2], "Repeatable key action mismatch")
  local delayTimer = state.repeatTimers[pair[1]]
  assertEq(delayTimer.delay, pair[3], "Per-key repeat delay mismatch")
  RC.testTriggerKey(pair[1], true, false)
  assertEq(#executed, 1, "Hardware duplicate must not fire extra delete/page action")
  delayTimer.callback()
  assertEq(#executed, 2, "Holding must repeat delete/page action")
  local repeatTimer = state.repeatTimers[pair[1]]
  assertEq(repeatTimer.delay, pair[4], "Per-key repeat interval mismatch")
  RC.testTriggerKey(pair[1], false, false)
  assertTrue(repeatTimer.stopped, "Releasing must stop repeat")
  assertEq(#executed, 2, "Releasing must not trigger an extra action")
end
executed = {}
RC.testTriggerKey("left", true, false)
assertEq(#executed, 1, "Arrow must fire immediately on down")
assertEq(executed[1].action, "key:left", "Arrow must have no Option modifier")
local repeatTimer = state.repeatTimers.left
RC.testTriggerKey("left", true, false)
assertEq(state.repeatTimers.left, repeatTimer, "Hardware repeats must not add timers")
repeatTimer.callback()
assertEq(#executed, 2, "Arrow must repeat after delay")
local everyTimer = state.repeatTimers.left
testTarget = { bundleID = "com.googlecode.iterm2", pid = 1, windowID = 1, element = "pane-2", navigationEpoch = 0 }
everyTimer.callback()
assertEq(#executed, 2, "Repeat must stop when pane changes")
assertTrue(everyTimer.stopped, "Repeat timer must stop on target change")
RC.testTriggerKey("left", false, false)

executed = {}
RC.testTriggerKey("ok", true, false)
testTarget = { bundleID = "com.googlecode.iterm2", pid = 1, windowID = 2, element = "pane-2", navigationEpoch = 0 }
RC.testTriggerKey("ok", false, false)
assertEq(#executed, 0, "Release in a different window must not submit")

executed = {}
RC.testTriggerKey("ok", true, false)
RC.testFireTimer("ok")
RC.testTriggerKey("ok", false, false)
assertEq(#executed, 1, "Long OK must submit only once")
assertEq(executed[1].action, "key:return", "Long OK must not restart a command")

executed = {}
state.reviewMode = true
RC.testTriggerKey("back", true, false)
assertEq(#executed, 1, "Back must delete on the first press even in review mode")
assertEq(executed[1].action, "key:delete", "Back must send Backspace, never Escape")
assertFalse(state.reviewMode, "Back must return to input before deleting")
RC.testTriggerKey("back", false, false)
assertEq(#executed, 1, "Back release must not add another deletion")

state.config.settings.targetBundleID = "com.googlecode.iterm2"
state._testBundleID = "com.test.browser"
executed = {}
RC.testTriggerKey("ok", true, false)
RC.testTriggerKey("ok", false, false)
assertEq(#executed, 0, "Remote must not submit in other apps")
RC.testTriggerKey("home", true, false)
RC.testTriggerKey("home", false, false)
assertEq(executed[1].action, "action:focus_iterm", "Home must remain available outside iTerm2")
state.config.settings.targetBundleID = nil
state._testBundleID = "com.googlecode.iterm2"

local a = { bundleID = "com.googlecode.iterm2", pid = 1, windowID = 1, element = "pane-1", navigationEpoch = 0 }
local b = { bundleID = "com.googlecode.iterm2", pid = 1, windowID = 1, element = "pane-1", navigationEpoch = 1 }
assertFalse(InputTarget.matches(a, b), "Remote navigation must defer voice output")
assertTrue(InputTarget.matches(a, b, true), "Explicit recovery can ignore the navigation epoch")
b.element = "pane-2"
assertFalse(InputTarget.matches(a, b, true), "Recovery must still require the original input area")
assertFalse(InputTarget.matches(nil, a), "Missing target must fail closed")
b.element = a.element
b.sessionLocked = true
assertFalse(InputTarget.matches(a, b, true), "Voice output must not paste while locked")

-- Test real dispatcher guards without recording or inserting text.
local savedVoiceInput = VoiceInput
local savedStroke = hs.eventtap.keyStroke
local inserted, sent = 0, 0
hs.eventtap.keyStroke = function() sent = sent + 1 end
local epoch = state.navigationEpoch
state.reviewMode = true
RC._mockExecuteAction = nil
RC._executeAction("key:pageup", "volume_up", "down")
assertEq(state.navigationEpoch, epoch, "Paging must not invalidate the voice target")
assertTrue(state.reviewMode, "Paging must not exit scrollback mode")
sent = 0
VoiceInput = { stopping = true }
RC._mockExecuteAction = nil
RC._executeAction("key:return", "ok", "tap")
assertEq(sent, 0, "OK must not submit while ASR is finalizing")
VoiceInput = { pastePending = true }
RC._executeAction("key:return", "ok", "tap")
assertEq(sent, 0, "OK must wait for delayed clipboard insertion")
VoiceInput = { pendingText = "preserved", resumePending = function() inserted = inserted + 1 end }
RC._executeAction("key:return", "ok", "tap")
assertEq(inserted, 1, "First OK must recover pending text")
assertEq(sent, 0, "Recovery must not also submit")
VoiceInput = savedVoiceInput
hs.eventtap.keyStroke = savedStroke
RC._mockExecuteAction = mockExecute
print("  ✓ Repeats, focus changes, single Enter, recovery, and iTerm2-only routing verified.")

print("[Test 13] Disconnect, reconnect and lock cleanup...")
local tapStarts, tapStops, voiceStops = 0, 0, 0
state.eventtap = {
  start = function() tapStarts = tapStarts + 1 end,
  stop = function() tapStops = tapStops + 1 end,
}
VoiceInput = { active = true, stop = function() voiceStops = voiceStops + 1 end }
state.connectedDeviceCount = 0
RC._setDeviceConnected(true)
RC._setDeviceConnected(true)
assertEq(tapStarts, 1, "Multiple HID services must start the tap only once")
state.mouseMode = true
executed = {}
RC.testTriggerKey("right", true, false)
local disconnectedMouseTimer = state.mouseTimer
assertTrue(disconnectedMouseTimer ~= nil, "Mouse movement timer must be active")
state.keyTimers.power = fakeTimer(0.8, function() end)
state.doubleTapTimers.home = fakeTimer(0.25, function() end)
state.repeatTimers.left = fakeTimer(0.09, function() end)
local hold, double, repeating = state.keyTimers.power, state.doubleTapTimers.home, state.repeatTimers.left
state.pendingDoubleTap.home = true
state.activeKeys.voice = "voice"
state.pressContexts.power = {}
state.reviewMode = true
RC._setDeviceConnected(false)
assertFalse(disconnectedMouseTimer.stopped, "Removing one HID service must not stop a still-connected remote")
RC._setDeviceConnected(false)
assertTrue(disconnectedMouseTimer.stopped, "Disconnect must stop mouse movement")
assertTrue(hold.stopped and double.stopped and repeating.stopped, "Disconnect must stop every input timer")
assertEq(state.mouseTimer, nil, "Mouse timer must be released")
assertEq(state.mouseHeldKey, nil, "Held mouse direction must be cleared")
for _, name in ipairs({ "keyTimers", "doubleTapTimers", "repeatTimers", "pendingDoubleTap", "activeKeys", "pressContexts" }) do
  assertEq(next(state[name]), nil, "Disconnect must clear " .. name)
end
assertFalse(state.mouseMode or state.reviewMode, "Disconnect must reset temporary modes")
assertEq(voiceStops, 1, "Disconnect must finish a remote voice press")
assertEq(tapStops, 1, "Disconnect must suspend the keyboard tap")
local actionCount = #executed
disconnectedMouseTimer.callback()
assertEq(#executed, actionCount, "A stale mouse callback must not move after disconnect")
RC._setDeviceConnected(true)
assertEq(tapStarts, 2, "Reconnect must resume the keyboard tap")
state.mouseMode = true
RC.testTriggerKey("right", true, false)
actionCount = #executed
disconnectedMouseTimer.callback()
assertEq(#executed, actionCount, "A stale callback must not affect a new mouse press")
RC._setDeviceConnected(false)
assertEq(voiceStops, 1, "Disconnect must preserve voice started from the keyboard")

-- Lock must cancel pending power holds and double taps without executing them.
state.mouseMode = false
executed = {}
RC.testTriggerKey("power", true, false)
local lockedHold = state.keyTimers.power
state.doubleTapTimers.home = fakeTimer(0.25, function() end)
local lockedDouble = state.doubleTapTimers.home
RC._onSessionLock()
assertTrue(lockedHold.stopped and lockedDouble.stopped, "Lock must cancel holds and double taps")
lockedHold.callback()
assertEq(#executed, 0, "A stale power hold must not open a panel while locked")
assertEq(voiceStops, 2, "Lock must stop active voice regardless of its entry point")
state.sessionLocked = false
state.eventtap = nil
VoiceInput = savedVoiceInput

-- A repeat delay already queued before cleanup must not restart repetition.
executed = {}
RC.testTriggerKey("left", true, false)
local disconnectedRepeat = state.repeatTimers.left
RC._clearInputState()
RC.testTriggerKey("left", true, false)
local newRepeat = state.repeatTimers.left
actionCount = #executed
disconnectedRepeat.callback()
assertEq(#executed, actionCount, "A stale repeat must not execute after reconnect")
assertEq(state.repeatTimers.left, newRepeat, "A stale delay must not replace the new repeat timer")
RC._clearInputState()
print("  ✓ Disconnect stops all input; reconnect resumes listening; lock cancels queued actions.")

print("[Test 14] IOHID task lifecycle and idle keyboard tap...")
local originalExecute, originalTaskNew = hs.execute, hs.task.new
local originalTapNew, originalHotkeyBind = hs.eventtap.new, hs.hotkey.bind
local originalWatcherNew, originalAttributes = hs.caffeinate.watcher.new, hs.fs.attributes
local originalShutdown = hs.shutdownCallback
local tasks, lifecycleTap, lockCallback = {}, nil, nil
hs.execute = function() return "", true end
hs.fs.attributes = function(path, attr)
  if path:match("/listener$") then return "file" end
  return originalAttributes(path, attr)
end
hs.task.new = function(_, complete, stream)
  local task = { complete = complete, stream = stream, running = false }
  function task:isRunning() return self.running end
  function task:start() self.running = true; return true end
  function task:terminate() self.running = false end
  function task:pid() return nil end
  tasks[#tasks + 1] = task
  return task
end
hs.eventtap.new = function(_, callback)
  lifecycleTap = { enabled = false, callback = callback }
  function lifecycleTap:start() self.enabled = true end
  function lifecycleTap:stop() self.enabled = false end
  return lifecycleTap
end
hs.hotkey.bind = function() return { delete = function() end } end
hs.caffeinate.watcher.new = function(callback)
  lockCallback = callback
  return { start = function() end, stop = function() end }
end
local function emit(task, event)
  return task.stream(task, hs.json.encode({ event = event }) .. "\n", "")
end
RC.start()
assertFalse(lifecycleTap.enabled, "Starting without a device must leave the tap idle")
emit(tasks[1], "device_matched")
assertTrue(lifecycleTap.enabled, "A matching device must enable isolation")
assertTrue(lifecycleTap.callback({ getKeyCode = function() return 90 end }), "F20 must be swallowed")
assertFalse(lifecycleTap.callback({ getKeyCode = function() return 36 end }), "Physical Return must pass through")
state.mouseMode = true
RC.testTriggerKey("right", true, false)
local exitedMouseTimer = state.mouseTimer
tasks[1].running = false
tasks[1].complete(1, "", "failure")
assertTrue(exitedMouseTimer.stopped, "A listener failure must stop mouse movement")
assertFalse(lifecycleTap.enabled, "An unlocked listener failure must disable the keyboard tap")
assertEq(state.connectedDeviceCount, 0, "A failed listener must clear connection state")

RC.start()
local oldTask = tasks[2]
emit(oldTask, "device_matched")
RC.start()
assertFalse(lifecycleTap.enabled, "Restart must wait for a fresh device notification")
assertFalse(emit(oldTask, "device_matched"), "A superseded listener must not deliver input")
oldTask.complete(0, "", "")
assertEq(state.hidTask, tasks[3], "An old completion must not clear the replacement listener")
emit(tasks[3], "device_matched")
RC._onSessionLock()
tasks[3].running = false
tasks[3].complete(1, "", "failure")
assertTrue(lifecycleTap.enabled, "A locked listener failure must retain key isolation")
lockCallback(hs.caffeinate.watcher.screensDidUnlock)
assertFalse(lifecycleTap.enabled, "Unlock after listener failure must release isolation")
RC.stop()
hs.execute, hs.task.new = originalExecute, originalTaskNew
hs.eventtap.new, hs.hotkey.bind = originalTapNew, originalHotkeyBind
hs.caffeinate.watcher.new, hs.fs.attributes = originalWatcherNew, originalAttributes
hs.shutdownCallback = originalShutdown
print("  ✓ Idle tap, real task callbacks, failure cleanup, stale tasks and locked isolation verified.")

-- Teardown (Algorithm G): stop all timers before clearing mock, so background timers never fire to real desktop
for _, t in pairs(state.keyTimers or {}) do pcall(function() t:stop() end) end
state.keyTimers = {}
for _, t in pairs(state.doubleTapTimers or {}) do pcall(function() t:stop() end) end
state.doubleTapTimers = {}
if state.mouseTimer ~= nil then
  pcall(function() state.mouseTimer:stop() end)
  state.mouseTimer = nil
end
if RC.stopMouseTimer then
  RC.stopMouseTimer()
end
state.mouseMode = false
state.sessionLocked = false

for _, t in pairs(state.repeatTimers) do t:stop() end
state.repeatTimers = {}
InputTarget.capture = originalCapture
hs.timer.doAfter, hs.timer.doEvery = originalDoAfter, originalDoEvery
hs.alert.show = originalAlertShow
assertEq(#hs.alert._visibleAlerts, visibleAlertsBefore, "Tests must not leave visible alerts")

-- Restore hook only after timers are stopped
RC._mockExecuteAction = nil

print("\n=======================================================")
print("ALL TESTS PASSED: Remote Control Engine regression checks passed.")
print("=======================================================")
return true
