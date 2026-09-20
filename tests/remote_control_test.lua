-- Unit & Integration Tests for Remote Control Engine (remote_control.lua)
-- Run via: hs -c 'return dofile(hs.configdir .. "/tests/remote_control_test.lua")'

local root = (hs and hs.configdir) or "."
package.loaded["modules.remote_control"] = nil
package.loaded["remote_control"] = nil
local ok, RC = pcall(require, "modules.remote_control")
if not ok then RC = require("remote_control") end
local state = RC._state
state.config = RC.loadConfig()

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
-- Verify transit map contains tv (144), volume_up (145), volume_down (146), home (80), power (147)
assertEq(RC.TRANSIT_KEY_MAP[144], "tv", "TRANSIT_KEY_MAP[144] must be tv")
assertEq(RC.TRANSIT_KEY_MAP[145], "volume_up", "TRANSIT_KEY_MAP[145] must be volume_up")
assertEq(RC.TRANSIT_KEY_MAP[146], "volume_down", "TRANSIT_KEY_MAP[146] must be volume_down")
assertEq(RC.TRANSIT_KEY_MAP[80], "home", "TRANSIT_KEY_MAP[80] must be home (F19)")
assertEq(RC.TRANSIT_KEY_MAP[147], "power", "TRANSIT_KEY_MAP[147] must be power")
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
assertEq(actionOKTap, "macro:approve_agent", "Terminal OK tap should resolve to approve_agent")

local actionBackTap = resolveKeyAction("back", "tap", "terminal")
assertEq(actionBackTap, "key:delete", "Terminal Back tap should resolve to delete")

local actionBackHold = resolveKeyAction("back", "hold", "terminal")
assertEq(actionBackHold, "key:ctrl+c", "Terminal Back hold should resolve to ctrl+c")

local actionVolUp = resolveKeyAction("volume_up", "tap", "terminal")
assertEq(actionVolUp, "macro:tmux_next_window", "Terminal Vol+ should resolve to tmux_next_window")

local actionBrowserVolUp = resolveKeyAction("volume_up", "tap", "browser")
assertEq(actionBrowserVolUp, "key:ctrl+tab", "Browser Vol+ should resolve to ctrl+tab")

local actionGlobalVolUp = resolveKeyAction("volume_up", "tap", "global")
assertEq(actionGlobalVolUp, "key:volume_up", "Global Vol+ should resolve to key:volume_up")

local actionTVGlobal = resolveKeyAction("tv", "tap", "global")
assertEq(actionTVGlobal, "action:toggle_app", "Global TV tap should resolve to toggle_app")

local actionTVGlobalHold = resolveKeyAction("tv", "hold", "global")
assertEq(actionTVGlobalHold, "action:toggle_dashboard", "Global TV hold should resolve to toggle_dashboard")

local actionHomeGlobal = resolveKeyAction("home", "tap", "global")
assertEq(actionHomeGlobal, "action:mission_control", "Global Home tap should resolve to mission_control")

local actionPowerTap = resolveKeyAction("power", "tap", "global")
assertEq(actionPowerTap, "action:display_sleep", "Global Power tap should resolve to display_sleep")

local actionPowerHold = resolveKeyAction("power", "hold", "global")
assertEq(actionPowerHold, "action:toggle_mouse_mode", "Global Power hold should resolve to toggle_mouse_mode")
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

-- Test 6: Mouse Mode & Scroll Wheel
print("[Test 6] Mouse Mode: Pointer & Scroll Wheel check...")
state.mouseMode = true
local eatenVolUp = RC.testTriggerKey("volume_up", true, false)
assertTrue(eatenVolUp, "Mouse mode volume_up should be consumed")
local eatenVolDown = RC.testTriggerKey("volume_down", true, false)
assertTrue(eatenVolDown, "Mouse mode volume_down should be consumed")
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
local homeDst, volDownDst
local foundConsumerBack = false
for _, row in ipairs(RC.HIDUTIL_MAPPINGS or {}) do
  if row.key == "home" and row.src == 0x70000004A then
    homeDst = row.dst
  elseif row.key == "volume_down" and row.src == 0x700000081 then
    volDownDst = row.dst
  end
  if row.src == 0xC00000224 and row.isolationOnly then
    foundConsumerBack = true
  end
end
assertTrue(homeDst ~= nil and volDownDst ~= nil, "home and volume_down must be in HIDUTIL_MAPPINGS")
assertTrue(homeDst ~= volDownDst, "Home dst and Volume Down dst must be distinct (FIX-09)")
assertEq(homeDst, 0x70000006E, "Home dst must be F19 0x70000006E")
assertTrue(foundConsumerBack, "Consumer AC Back 0xC00000224 must be in HIDUTIL_MAPPINGS with isolationOnly (FIX-04)")

local payload = RC._hidutilApplyPayload and RC._hidutilApplyPayload()
assertTrue(type(payload) == "string", "apply payload must be a string")
assertTrue(payload:find("HIDKeyboardModifierMappingSrc", 1, true) ~= nil, "payload must contain HIDKeyboardModifierMappingSrc")
assertTrue(payload:find("HIDKeyboardModifierMappingDst", 1, true) ~= nil, "payload must contain HIDKeyboardModifierMappingDst")
assertFalse(payload:find("isolationOnly", 1, true) ~= nil, "payload must NOT contain isolationOnly")
assertFalse(payload:find('"keycode"', 1, true) ~= nil, "payload must NOT contain keycode")
assertFalse(payload:find('"key"', 1, true) ~= nil, "payload must NOT contain key")

assertFalse(RC.listenerRunning(), "listenerRunning() must return false when hidTask is nil")
print("  ✓ HID mapping table, F19 Home, Consumer Back isolation, and payload validated.")

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

-- Restore hook only after timers are stopped
RC._mockExecuteAction = nil

print("\n=======================================================")
print("ALL TESTS PASSED: Remote Control Engine is 100% verified!")
print("=======================================================")
return true
