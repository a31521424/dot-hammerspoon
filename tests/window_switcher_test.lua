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
local visible = { b1, a1, b2, a2, unknown, broken }
local all = { a1, a2, b1, b2, amin, bmin, unknown, broken }
local function drawing()
  return setmetatable({}, { __index = function(_, method)
    return function(self, value)
      if method == "setFrame" then self.frame = value end
      return self
    end
  end })
end
local function timer() return { stop = function() end } end
local fakeHS = {
  logger = { new = function() return { wf = function() end, ef = function() end } end },
  mouse = { getCurrentScreen = function() return pointer end },
  screen = { mainScreen = function() return a end },
  geometry = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end,
  timer = { doAfter = timer },
  eventtap = { checkKeyboardModifiers = function() return { alt = alt } end },
  hotkey = { bind = function() return { delete = function() end } end },
  window = {
    focusedWindow = function() return focused end,
    orderedWindows = function() return visible end,
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
local env = setmetatable({ hs = fakeHS }, { __index = _G })
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

-- Hold Alt: changing focus/pointer must not change this session's screen.
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
alt = false
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
return "PASS: pointer-based screen ownership, session isolation, layout, movement, minimized windows, fallbacks, reverse/click selection and all-screen opt-out"
