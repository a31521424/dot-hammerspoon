-- Run from the project root with Lua, or via Hammerspoon's CLI:
-- hs -c 'return dofile(hs.configdir .. "/tests/window_switcher_test.lua")'
local root = (hs and hs.configdir) or "."
local function screen(id, x)
  return {
    id = function() return id end,
    frame = function() return { x = x, y = 0, w = 1920, h = 1080 } end,
  }
end
local a, b = screen(1, 0), screen(2, 1920)
local app = {
  name = function() return "Editor" end,
  bundleID = function() return "test.editor" end,
  kind = function() return 1 end,
  isHidden = function() return false end,
}
local function window(id, owner, minimized)
  return {
    owner = owner,
    id = function() return id end,
    application = function() return app end,
    isMinimized = function() return minimized or false end,
    isVisible = function() return not minimized end,
    subrole = function() return "AXStandardWindow" end,
    title = function() return "Window " .. id end,
    frame = function() return { w = 800, h = 600 } end,
    screen = function(self) return self.owner end,
    unminimize = function() end,
    raise = function() end,
    focus = function(self) self.focused = true end,
  }
end
local a1, a2, b1, b2 = window(1, a), window(2, a), window(3, b), window(4, b)
local amin, bmin = window(5, a, true), window(6, b, true)
local unknown = window(7, nil)
local broken = window(8, nil)
broken.screen = function() error("window disappeared") end
local focused, pointer, alt = b1, a, true
local cmd, shift, secure = true, false, false
local now = 100
local enumerationCount = 0
local timers = {}
local visible = { b1, a1, b2, a2, unknown, broken }
local all = { a1, a2, b1, b2, amin, bmin, unknown, broken }
local function drawing()
  return setmetatable({}, { __index = function(_, method)
    return function(self, value)
      if method == "setFrame" then self.frame = value end
      if method == "setText" then self.text = value end
      return self
    end
  end })
end
local function timer(delay, callback)
  local result = { delay = delay, callback = callback,
    stop = function(self) self.stopped = true end }
  timers[#timers + 1] = result
  return result
end
local types = { keyDown = 10, keyUp = 11, flagsChanged = 12 }
local fakeHS = {
  logger = { new = function() return { wf = function() end, ef = function() end } end },
  mouse = { getCurrentScreen = function() return pointer end },
  screen = { mainScreen = function() return a end },
  geometry = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end,
  timer = { doAfter = timer, doEvery = timer, absoluteTime = function() return now * 1000000000 end },
  keycodes = { map = { tab = 48, escape = 53 } },
  eventtap = {
    event = { types = types, properties = { keyboardEventAutorepeat = 8 } },
    checkKeyboardModifiers = function() return { alt = alt, cmd = cmd, shift = shift } end,
    isSecureInputEnabled = function() return secure end,
    new = function(eventTypes, callback)
      return { types = eventTypes, callback = callback,
        start = function(self) self.enabled = true end,
        stop = function(self) self.enabled = false end,
        isEnabled = function(self) return self.enabled end }
    end,
  },
  hotkey = { bind = function() error("switcher must never bind Option-Tab") end },
  window = {
    focusedWindow = function() return focused end,
    orderedWindows = function() enumerationCount = enumerationCount + 1; return visible end,
    allWindows = function() return all end,
    filter = {
      isGuiApp = function() return true end,
      ignoreInDefaultFilter = {},
      new = function() return { pause = function() end } end,
    },
    switcher = { new = function(filter, ui)
      ui.titleHeight = 16
      local sw = { ui = ui, drawings = { background = drawing(), highlightRect = drawing() } }
      local function cycle(self, direction)
        if self.windows == nil then
          self.windows = filter:getWindows()
          if #self.windows == 0 then self.windows = nil; return end
          self.selected = 1
          self.modsTimer = timer()
          for i = 1, #self.windows do
            self.drawings[i] = { icon = drawing(), titleRect = drawing(), titleText = drawing() }
          end
        end
        self.selected = ((self.selected - 1 + direction) % #self.windows) + 1
      end
      sw.next = function(self) cycle(self, 1) end
      sw.previous = function(self) cycle(self, -1) end
      return sw
    end },
  },
}
local fakeNative = { start = function(options)
  local driver = { active = true, sessionActive = false }
  function driver:setSessionActive(active, gesture) self.sessionActive = active; self.sessionGesture = gesture end
  function driver:stop() self.active = false end
  function driver.emit(event) options.onAction(event) end
  function driver.fail() driver.active = false; options.onUnavailable() end
  return driver
end }
local env = setmetatable({ hs = fakeHS, require = function(name)
  if name == "modules.window_switcher.native_hotkeys" then return fakeNative end
  return require(name)
end }, { __index = _G })
local switcherPath = root .. "/modules/window_switcher/init.lua"
if hs and hs.fs and hs.fs.attributes(switcherPath, "mode") ~= "file" then
  switcherPath = root .. "/window_switcher.lua"
end
local module = assert(loadfile(switcherPath, "t", env))()
local controller = module.start()
local function expectIDs(windows, expected)
  local ids = {}
  for _, win in ipairs(windows) do ids[#ids + 1] = win:id() end
  local actual = table.concat(ids, ",")
  assert(actual == expected, actual .. " ~= " .. expected)
end

-- Ownership is per window, even when all windows belong to the same app.
-- The pointer wins even with focus on the other screen; MRU order is preserved.
expectIDs(controller.windowFilter:getWindows(), "1,2,5")
assert(controller:candidateCount() == 3)
controller.next()
expectIDs(controller.switcher.windows, "1,2,5")
assert(controller.switcher.windows[controller.switcher.selected] == a2)
assert(controller.switcher.drawings.background.frame.x < 1920)

-- Hold Command: changing focus/pointer must not change this session's screen.
focused, pointer = a1, b
controller.next()
expectIDs(controller.switcher.windows, "1,2,5")
expectIDs(controller.windowFilter:getWindows(), "1,2,5")
controller.cancel()
controller.previous()
expectIDs(controller.switcher.windows, "3,4,6")
assert(controller.switcher.windows[controller.switcher.selected] == bmin)
assert(controller.switcher.drawings.screenFrame.x == 1920)
assert(controller.switcher.drawings.background.frame.x >= 1920)
controller:clickIndex(1)
assert(b1.focused and controller.switcher.windows == nil)

-- A moved window changes ownership on the next invocation.
a2.owner = b
expectIDs(controller.windowFilter:getWindows(), "3,4,2,6")
focused, pointer = nil, a
expectIDs(controller.windowFilter:getWindows(), "1,5")
pointer = nil
expectIDs(controller.windowFilter:getWindows(), "1,5")

-- A screen with no candidates must never fall back to another display.
focused, pointer = nil, screen(3, 3840)
controller.next()
assert(controller.switcher.windows == nil)
cmd = false
focused, pointer = a1, a
controller.next()
assert(controller.switcher.windows == nil)
controller:stop()

-- The opt-out retains all-screen behavior; other filters still apply.
local global = module.start({ currentScreenOnly = false })
expectIDs(global.windowFilter:getWindows(), "3,1,4,2,7,8,5,6")
global:stop()
local noMinimized = module.start({ includeMinimized = false })
expectIDs(noMinimized.windowFilter:getWindows(), "1")
noMinimized:stop()

-- Remote source tests (FIX-11)
local remoteCtrl = module.start()
cmd = false
focused, pointer = a1, a

-- Direct next() without cmd=true must remain nil (stale activation guard)
remoteCtrl.next()
assert(remoteCtrl.switcher.windows == nil, "next() without cmd must not activate")
assert(remoteCtrl.isVisible() == false, "isVisible() must be false")

-- Remote next({source="remote"}) must activate even if alt=false
remoteCtrl.next({ source = "remote" })
assert(remoteCtrl.switcher.windows ~= nil, "next({source='remote'}) must open switcher")
assert(remoteCtrl.isVisible() == true, "isVisible() must be true")

-- Remote previous({source="remote"})
remoteCtrl.previous({ source = "remote" })
assert(remoteCtrl.isVisible() == true, "isVisible() must remain true after previous")

-- Remote cancel: dismiss without focusing new window
remoteCtrl.cancel()
assert(remoteCtrl.switcher.windows == nil, "switcher should be dismissed after cancel")
assert(remoteCtrl.isVisible() == false, "isVisible() must be false after cancel")

-- Remote next + confirm: focuses window
remoteCtrl.next({ source = "remote" })
assert(remoteCtrl.isVisible() == true)
remoteCtrl.confirm()
assert(remoteCtrl.switcher.windows == nil, "switcher should be dismissed after confirm")
assert(remoteCtrl.isVisible() == false)

remoteCtrl:stop()

-- Untitled window tests (FIX: vivo remote screen support)
local vivoApp = {
  name = function() return "手机投屏" end,
  bundleID = function() return "com.vivo.pcsuite.vivoScreen" end,
  kind = function() return 1 end,
  isHidden = function() return false end,
}
local vivoWin = {
  owner = a,
  id = function() return 99 end,
  application = function() return vivoApp end,
  isMinimized = function() return false end,
  isVisible = function() return true end,
  subrole = function() return "AXDialog" end,
  title = function() return "" end,
  frame = function() return { w = 613, h = 1404 } end,
  isMaximizable = function() return true end,
  zoomButtonRect = function() return { w = 16, h = 16 } end,
  screen = function(self) return self.owner end,
  unminimize = function() end,
  raise = function() end,
  focus = function(self) self.focused = true end,
}
local vivoToolbar = {
  owner = a,
  id = function() return 98 end,
  application = function() return vivoApp end,
  isMinimized = function() return false end,
  isVisible = function() return true end,
  subrole = function() return "AXDialog" end,
  title = function() return "" end,
  frame = function() return { w = 398, h = 37 } end,
  isMaximizable = function() return false end,
  zoomButtonRect = function() return { w = 0, h = 0 } end,
  screen = function(self) return self.owner end,
  unminimize = function() end,
  raise = function() end,
  focus = function(self) self.focused = true end,
}

local origVisible, origAll = visible, all
visible = { vivoWin, vivoToolbar, a1 }
all = { vivoWin, vivoToolbar, a1 }
cmd = true
focused, pointer = a1, a

local untitledCtrl = module.start()
local untitledWindows = untitledCtrl.windowFilter:getWindows()
expectIDs(untitledWindows, "99,1")

untitledCtrl.next()
assert(untitledCtrl.switcher.windows ~= nil)
expectIDs(untitledCtrl.switcher.windows, "99,1")
-- Verify title resolution set text on item 1 (vivoWin) to application name
local item1Text = untitledCtrl.switcher.drawings[1].titleText.text
assert(item1Text == "手机投屏", "titleText should fall back to app name '手机投屏', got: " .. tostring(item1Text))

untitledCtrl:stop()
visible, all = origVisible, origAll

local commandCtrl = module.start({ nativeCommandTab = true })
local native = commandCtrl.nativeHotkeys
assert(next(commandCtrl.hotkeys) == nil, "Command-Tab must be the only shortcut family")
assert(commandCtrl.eventtap == nil, "Lua must not observe modifier events on a second input channel")
local function flushCommands()
  for _, scheduled in ipairs(timers) do
    if scheduled.delay == 0 and not scheduled.stopped and not scheduled.fired then
      scheduled.fired = true
      scheduled.callback()
    end
  end
end
local function emit(event, gesture, started, repeated)
  native.emit({ event = event, gesture = gesture, started = started, repeated = repeated })
end
focused, pointer, cmd = a1, a, true
emit("next", 1, 101)
assert(not commandCtrl.isVisible(), "input callback must defer AX work")
flushCommands()
assert(commandCtrl.isVisible() and commandCtrl.switcher.modsTimer == nil and native.sessionActive)
local firstIndex = commandCtrl.switcher.selected
emit("next", 1, 101, true)
flushCommands()
assert(commandCtrl.switcher.selected ~= firstIndex)
assert(commandCtrl.commandStats.presses == 1 and commandCtrl.commandStats.repeats == 1)
shift = true
emit("previous", 1, 101)
flushCommands()
assert(commandCtrl.switcher.selected == firstIndex)
local chosen = commandCtrl.switcher.windows[firstIndex]
chosen.focused = false
cmd = false
emit("confirm", 1, 101)
flushCommands()
assert(chosen.focused and not commandCtrl.isVisible() and not native.sessionActive)

-- A release delivered before late Carbon steps retains the original snapshot.
-- Current Command is already held for the next gesture; never consult it.
cmd = true
chosen.focused = false
emit("confirm", 2, 102)
flushCommands()
local reads = enumerationCount
emit("next", 2, 102)
flushCommands()
assert(chosen.focused and not commandCtrl.isVisible())
assert(enumerationCount == reads + 1)
local snapshot = visible
visible = { amin, a1 } -- A fresh MRU query would now have a different order.
a1.focused = false
emit("next", 2, 102)
emit("confirm", 2, 102)
flushCommands()
assert(a1.focused and not commandCtrl.isVisible(), "late steps must continue the same snapshot")
assert(enumerationCount == reads + 1, "late steps must not enumerate a fresh MRU list")
visible = snapshot
emit("next", 3, 103)
flushCommands()
assert(commandCtrl.isVisible())
emit("confirm", 2, 102) -- stale confirmation cannot close gesture 3
flushCommands()
assert(commandCtrl.isVisible())
emit("confirm", 3, 103)
flushCommands()
assert(not commandCtrl.isVisible())

-- Two quick independent gestures remain two confirmations in one stdout batch.
chosen.focused = false
emit("next", 4, 104)
emit("confirm", 4, 104)
emit("next", 5, 105)
flushCommands()
assert(chosen.focused and commandCtrl.isVisible())
emit("confirm", 5, 105)
flushCommands()

-- Secure Input does not change the native action/confirmation protocol.
secure = true
emit("next", 6, 106)
emit("previous", 6, 106)
flushCommands()
local target = commandCtrl.switcher.windows[commandCtrl.switcher.selected]
target.focused = false
emit("confirm", 6, 106)
flushCommands()
assert(target.focused and not commandCtrl.isVisible())
secure = false

-- Cancel suppresses queued repeats and does not focus a target.
chosen.focused = false
emit("next", 7, 107)
emit("cancel", 7, 107)
emit("next", 7, 107, true)
flushCommands()
assert(not commandCtrl.isVisible() and not chosen.focused)

-- A Carbon Escape callback may arrive after its gesture's release. Restore
-- original focus, while an Escape from an older gesture cannot touch a new one.
a1.focused = false
emit("next", 7, 107.5)
emit("confirm", 7, 107.5)
flushCommands()
a1.focused = false
emit("cancel", 7, 107.5)
flushCommands()
assert(a1.focused and not commandCtrl.isVisible(), "late Escape must restore original focus")

-- Remote takeover before deferred native work flushes discards that work.
now = 110
emit("next", 8, 108)
commandCtrl.next({ source = "remote" })
flushCommands()
assert(commandCtrl.isVisible() and not native.sessionActive)
-- Include an old gesture that is first seen only after the takeover.
emit("next", 9, 109)
emit("next", 8, 108, true)
emit("confirm", 8, 108)
flushCommands()
assert(commandCtrl.isVisible() and not native.sessionActive)
-- Only a new Command down can take over again.
emit("next", 10, 111)
flushCommands()
assert(commandCtrl.isVisible() and native.sessionActive and native.sessionGesture == 10)
emit("confirm", 10, 111)
flushCommands()
assert(not commandCtrl.isVisible())

-- Mouse callbacks, external cancel and stop also reject queued/late old work.
now = 120
emit("next", 11, 121)
flushCommands()
now = 122
emit("next", 11, 121, true)
commandCtrl:clickIndex(1)
flushCommands()
assert(not commandCtrl.isVisible())
emit("next", 12, 123)
now = 124
commandCtrl.cancel()
flushCommands()
assert(not commandCtrl.isVisible())
emit("next", 13, 125)
commandCtrl:stop()
flushCommands()
assert(not native.active and not commandCtrl.isVisible())

local replacement = module.start({ nativeCommandTab = true })
replacement.nativeHotkeys.emit({ event = "next", gesture = 1, started = 130 })
flushCommands()
assert(replacement.isVisible())
replacement.nativeHotkeys.fail()
assert(not replacement.isVisible())
module.stop()
assert(not replacement.nativeHotkeys.active)
return "PASS: Command-only shortcuts, window filters, gesture ordering, late steps, Secure Input, remote/mouse takeover and teardown"
