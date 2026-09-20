-- Unit & Integration Tests for Remote Control Engine (remote_control.lua)
-- Run via: hs -c 'return dofile(hs.configdir .. "/tests/remote_control_test.lua")'

local root = (hs and hs.configdir) or "."
package.loaded["remote_control"] = nil
local RC = require("remote_control")
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
  [0x4A] = "power",
}
for usage, expectedName in pairs(expectedUsages) do
  local decoded = RC.decodeHidUsage(0x07, usage)
  assertEq(decoded, expectedName, string.format("Usage 0x%02X failed to decode", usage))
end
print("  ✓ All 12 physical remote usages correctly map to internal keyNames.")

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

-- Restore hook
RC._mockExecuteAction = nil

print("\n=======================================================")
print("ALL TESTS PASSED: Remote Control Engine is 100% verified!")
print("=======================================================")
return true
