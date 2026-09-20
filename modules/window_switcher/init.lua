local M = {}

local log = hs.logger.new("window-switcher", "warning")

local DEFAULT_ALLOWED_SUBROLES = {
  AXStandardWindow = true,
  AXDialog = true,
}

local DEFAULT_UI = {
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

  textColor = { red = 0.96, green = 0.96, blue = 0.98, alpha = 1 },
  backgroundColor = { red = 0.025, green = 0.03, blue = 0.04, alpha = 0.72 },
  titleBackgroundColor = { red = 0.04, green = 0.045, blue = 0.055, alpha = 0 },
  highlightColor = { red = 0.16, green = 0.40, blue = 0.80, alpha = 0.70 },
}

local function copyMap(value)
  local result = {}
  for key, item in pairs(value or {}) do
    result[key] = item
  end
  return result
end

local function copyArray(value)
  local result = {}
  for index, item in ipairs(value or {}) do
    result[index] = item
  end
  return result
end

local function mergeUI(overrides)
  local result = copyMap(DEFAULT_UI)
  for key, value in pairs(overrides or {}) do
    result[key] = value
  end
  return result
end

local function normalizeIgnored(ignored)
  ignored = ignored or {}

  local normalized = {
    bundleIDs = copyMap(ignored.bundleIDs),
    appNames = copyMap(ignored.appNames),
    titlePatterns = {},
  }

  for scope, patterns in pairs(ignored.titlePatterns or {}) do
    normalized.titlePatterns[scope] = copyArray(patterns)
    for _, pattern in ipairs(patterns) do
      local valid, err = pcall(string.match, "", pattern)
      if not valid then
        error(string.format("invalid ignored title pattern %q: %s", pattern, err), 3)
      end
    end
  end

  return normalized
end

local function matchesAny(value, patterns)
  for _, pattern in ipairs(patterns or {}) do
    if string.match(value, pattern) then
      return true
    end
  end
  return false
end

local function titleIsIgnored(title, appName, bundleID, titlePatterns)
  return matchesAny(title, titlePatterns["*"])
    or matchesAny(title, titlePatterns[appName])
    or (bundleID ~= nil and matchesAny(title, titlePatterns[bundleID]))
end

local function windowScreen(window)
  if window == nil then
    return nil
  end
  local ok, screen = pcall(function() return window:screen() end)
  return ok and screen or nil
end

local function currentScreen()
  -- The pointer defines the working screen, regardless of keyboard focus.
  local s = hs.mouse.getCurrentScreen and hs.mouse.getCurrentScreen()
  if s then return s end
  s = hs.screen.mainScreen and hs.screen.mainScreen()
  if s then return s end
  s = hs.screen.primaryScreen and hs.screen.primaryScreen()
  if s then return s end
  local all = hs.screen.allScreens and hs.screen.allScreens()
  return all and all[1] or nil
end

local function safeScreenFrame(screen)
  local s = screen or currentScreen()
  if s == nil then
    return nil
  end
  local ok, frame = pcall(function() return s:frame() end)
  return ok and frame or nil
end

local function makeWindowPredicate(config, ignored)
  local allowedSubroles = copyMap(config.allowedSubroles or DEFAULT_ALLOWED_SUBROLES)

  return function(window)
    local ok, allowed = pcall(function()
      if window == nil or window:id() == nil then
        return false
      end

      local application = window:application()
      if application == nil then
        return false
      end

      local appName = application:name()
      local bundleID = application:bundleID()
      if appName == nil or not hs.window.filter.isGuiApp(appName) then
        return false
      end
      if hs.window.filter.ignoreInDefaultFilter[appName] then
        return false
      end

      local appKind = application:kind()
      if appKind ~= nil and appKind < 0 then
        return false
      end

      if ignored.appNames[appName]
        or (bundleID ~= nil and ignored.bundleIDs[bundleID]) then
        return false
      end

      local hidden = application:isHidden()
      if hidden and not config.includeHidden then
        return false
      end

      local minimized = window:isMinimized()
      if minimized and not config.includeMinimized then
        return false
      end

      if not hidden and not minimized and not window:isVisible() then
        return false
      end

      if not allowedSubroles[window:subrole()] then
        return false
      end

      local title = window:title()
      if title == nil or string.match(title, "^%s*$") then
        return false
      end
      if titleIsIgnored(title, appName, bundleID, ignored.titlePatterns) then
        return false
      end

      local frame = window:frame()
      if frame == nil or frame.w == nil or frame.h == nil
        or frame.w <= 1 or frame.h <= 1 then
        return false
      end

      return true
    end)

    if not ok then
      log.wf("ignoring a window after an Accessibility error: %s", allowed)
      return false
    end
    return allowed
  end
end

local function bindOrFail(modifiers, key, pressed, repeated)
  local hotkey = hs.hotkey.bind(modifiers, key, pressed, nil, repeated)
  if hotkey == nil then
    error(string.format("could not bind %s+%s", table.concat(modifiers, "+"), key), 3)
  end
  return hotkey
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

-- Reposition the built-in switcher's existing drawing objects as a vertical
-- list. Selection, MRU order, repeat handling, and modifier release remain
-- entirely owned by hs.window.switcher.
local function layoutSwitcherAsList(switcher, screen)
  local windows = switcher.windows
  if windows == nil or #windows == 0 then
    return
  end

  local ui = switcher.ui
  local drawings = switcher.drawings
  if drawings == nil then
    return
  end

  local screenFrame = safeScreenFrame(screen)
  if screenFrame == nil then
    return
  end
  local availableWidth = math.max(240, screenFrame.w - 40)
  local minimumWidth = math.min(ui.listMinWidth, availableWidth)
  local maximumWidth = math.min(ui.listMaxWidth, availableWidth)
  local width = clamp(
    math.floor(screenFrame.w * ui.listWidthRatio),
    minimumWidth,
    maximumWidth
  )

  local minimumRowHeight = math.max(22, math.ceil(ui.titleHeight + 4))
  local availableHeight = math.max(100, screenFrame.h - 40)
  local rowHeight = math.min(
    ui.listRowHeight,
    math.floor((availableHeight - (ui.listPadding * 2)) / #windows)
  )
  rowHeight = math.max(minimumRowHeight, rowHeight)

  local height = (ui.listPadding * 2) + (rowHeight * #windows)
  local backgroundFrame = hs.geometry(
    math.floor(screenFrame.x + ((screenFrame.w - width) / 2)),
    math.floor(screenFrame.y + math.max(0, (screenFrame.h - height) / 2)),
    width,
    height
  )
  drawings.background:setFrame(backgroundFrame):setRoundedRectRadii(10, 10)

  local iconSize = math.min(ui.listIconSize, rowHeight - 6)
  local iconX = backgroundFrame.x + ui.listPadding + 7
  local titleX = iconX + iconSize + 10
  local titleWidth = backgroundFrame.w
    - (titleX - backgroundFrame.x)
    - ui.listPadding
    - 7

  for index = 1, #windows do
    local item = drawings[index]
    local rowY = backgroundFrame.y
      + ui.listPadding
      + ((index - 1) * rowHeight)
    local rowFrame = hs.geometry(
      backgroundFrame.x + ui.listPadding,
      rowY,
      backgroundFrame.w - (ui.listPadding * 2),
      rowHeight
    )
    local iconFrame = hs.geometry(
      iconX,
      rowY + math.floor((rowHeight - iconSize) / 2),
      iconSize,
      iconSize
    )
    local titleFrame = hs.geometry(
      titleX,
      rowY + math.floor((rowHeight - ui.titleHeight) / 2),
      titleWidth,
      ui.titleHeight
    )

    item.icon:setFrame(iconFrame)
    item.titleFrame = titleFrame
    item.titleRect:setFrame(titleFrame)
    item.titleText:setFrame(titleFrame)
    item.highlightFrame = rowFrame
    item.selRectFrame = rowFrame
  end

  drawings.size = titleWidth
  if switcher.selected ~= nil then
    drawings.highlightRect:setFrame(
      drawings[switcher.selected].highlightFrame
    )
  end
end

local function safeHide(drawing)
  if drawing ~= nil then
    pcall(function() drawing:hide() end)
  end
end

-- hs.window.switcher does not expose its internal exit function. This mirrors
-- only the small cleanup needed when a visible item is chosen with the mouse.
local function dismissWithoutFocus(switcher)
  if switcher == nil then
    return nil
  end
  if switcher.clearSession ~= nil then
    switcher.clearSession()
  end
  local windows = switcher.windows
  if windows == nil then
    return nil
  end

  if switcher.drawDelayed ~= nil then
    pcall(function() switcher.drawDelayed:stop() end)
  end
  if switcher.modsTimer ~= nil then
    pcall(function() switcher.modsTimer:stop() end)
    switcher.modsTimer = nil
  end

  local drawings = switcher.drawings
  if drawings ~= nil then
    safeHide(drawings.background)
    safeHide(drawings.highlightRect)
    safeHide(drawings.selRect)
    safeHide(drawings.selThumb)
    safeHide(drawings.selIcon)
    safeHide(drawings.selTitleRect)
    safeHide(drawings.selTitleText)

    for index = 1, #windows do
      local item = drawings[index]
      if item ~= nil then
        safeHide(item.icon)
        safeHide(item.thumb)
        safeHide(item.titleRect)
        safeHide(item.titleText)
      end
    end
  end

  switcher.windows = nil
  switcher.selected = nil
  return windows
end

local function clickWindow(switcher, index)
  local windows = switcher.windows
  local target = windows and windows[index] or nil
  if target == nil then
    return
  end

  dismissWithoutFocus(switcher)
  local ok, err = pcall(function()
    target:unminimize()
    target:raise()
    target:focus()
  end)
  if not ok then
    log.ef("could not focus clicked window: %s", err)
  end
end

local function attachClickCallbacks(switcher)
  local windows = switcher.windows
  if windows == nil then
    return
  end

  for index = 1, #windows do
    local windowIndex = index
    local item = switcher.drawings[index]
    local callback = function()
      clickWindow(switcher, windowIndex)
    end

    if item ~= nil then
      if item.icon ~= nil then
        item.icon:setClickCallback(callback)
      end
      if item.thumb ~= nil then
        item.thumb:setClickCallback(callback)
      end
      if item.titleRect ~= nil then
        item.titleRect:setClickCallback(callback)
      end
      if item.titleText ~= nil then
        item.titleText:setClickCallback(callback)
      end
    end
  end

  -- The selection highlight is drawn above the selected item, so it receives
  -- its own callback and resolves the current index at click time.
  switcher.drawings.highlightRect:setClickCallback(function()
    if switcher.selected ~= nil then
      clickWindow(switcher, switcher.selected)
    end
  end)
end

function M.start(options)
  options = options or {}
  local config = {
    includeMinimized = options.includeMinimized ~= false,
    includeHidden = options.includeHidden == true,
    currentScreenOnly = options.currentScreenOnly ~= false,
    allowedSubroles = options.allowedSubroles,
  }
  local ignored = normalizeIgnored(options.ignored)

  local predicate = makeWindowPredicate(config, ignored)
  local windowFilter = hs.window.filter.new(
    predicate,
    "alt-tab-filter",
    "warning"
  )
  local switcher
  local sessionScreen
  local activatingScreen
  local layoutRepairTimer = nil

  local function clearSession()
    sessionScreen = nil
    activatingScreen = nil
    if layoutRepairTimer ~= nil then
      layoutRepairTimer:stop()
      layoutRepairTimer = nil
    end
  end

  -- Use macOS WindowServer true Z-order (hs.window.orderedWindows) to guarantee
  -- that all windows across all applications (including multiple windows of the same app)
  -- are accurately enumerated and ordered by true MRU focus without relying on fragile
  -- or missing AXObserver events.
  function windowFilter.getWindows(self, sortOrder)
    local seen = {}
    local result = {}
    -- Read ownership on every new invocation, so dragged/restored windows and
    -- display changes are reflected without a stale per-window screen cache.
    local targetScreen = activatingScreen
      or (switcher and switcher.windows ~= nil and sessionScreen)
      or currentScreen()
    local targetScreenID
    if targetScreen ~= nil then
      local ok, id = pcall(function() return targetScreen:id() end)
      targetScreenID = ok and id or nil
    end

    local function isCandidate(win)
      if not predicate(win) then
        return false
      end
      if not config.currentScreenOnly then
        return true
      end
      local owner = windowScreen(win)
      if targetScreenID == nil or owner == nil then
        return false
      end
      local ok, ownerID = pcall(function() return owner:id() end)
      return ok and ownerID == targetScreenID
    end

    -- 1. Gather visible windows in exact front-to-back Z-order from macOS
    for _, win in ipairs(hs.window.orderedWindows()) do
      local id = win:id()
      if id ~= nil and not seen[id] then
        seen[id] = true
        if isCandidate(win) then
          table.insert(result, win)
        end
      end
    end

    -- 2. If minimized or hidden windows are included, find them from allWindows
    if config.includeMinimized or config.includeHidden then
      for _, win in ipairs(hs.window.allWindows()) do
        local id = win:id()
        if id ~= nil and not seen[id] then
          local isMin = win:isMinimized()
          local app = win:application()
          local isHid = app ~= nil and app:isHidden()
          if (config.includeMinimized and isMin) or (config.includeHidden and isHid) then
            seen[id] = true
            if isCandidate(win) then
              table.insert(result, win)
            end
          end
        end
      end
    end

    return result
  end

  switcher = hs.window.switcher.new(
    windowFilter,
    mergeUI(options.ui),
    "alt-tab-switcher",
    "warning"
  )
  switcher.clearSession = clearSession

  local function prepareListLayout(wasFresh)
    if not wasFresh then
      return
    end

    local activeWindows = switcher.windows
    if activeWindows == nil or #activeWindows == 0 then
      clearSession()
      return
    end

    layoutSwitcherAsList(switcher, sessionScreen)
    attachClickCallbacks(switcher)

    -- On the first invocation the native switcher fills in title text after
    -- its 150 ms display delay and briefly reapplies horizontal assumptions.
    -- Restore only the drawing frames afterwards; no input state is involved.
    if layoutRepairTimer ~= nil then
      layoutRepairTimer:stop()
    end
    layoutRepairTimer = hs.timer.doAfter(0.16, function()
      layoutRepairTimer = nil
      if switcher.windows == activeWindows then
        layoutSwitcherAsList(switcher, sessionScreen)
      end
    end)
  end

  local function isStaleQueuedActivation()
    -- If user is no longer holding Alt when a fresh activation is dispatched,
    -- this is a stale buffered event from event queue backlog.
    local mods = hs.eventtap.checkKeyboardModifiers(true)
    if mods == nil or not mods.alt then
      return true
    end
    return false
  end

  local function cycleWindow(backwards)
    local wasFresh = switcher.windows == nil
    if wasFresh and isStaleQueuedActivation() then
      clearSession()
      return
    end
    if wasFresh then
      sessionScreen = currentScreen()
      activatingScreen = sessionScreen
      -- The native switcher caches layout by window count. Invalidate it even
      -- when the next screen happens to have the same number of windows.
      if switcher.drawings then
        switcher.drawings.screenFrame = safeScreenFrame(sessionScreen)
        switcher.drawings.lastn = nil
      end
    end
    if backwards then
      switcher:previous()
    else
      switcher:next()
    end
    activatingScreen = nil
    if switcher.windows == nil then
      clearSession()
    end
    prepareListLayout(wasFresh)
  end

  local function nextWindow()
    cycleWindow(false)
  end

  local function previousWindow()
    cycleWindow(true)
  end

  local controller = {
    baseFilter = windowFilter,
    windowFilter = windowFilter,
    switcher = switcher,
    hotkeys = {
      next = bindOrFail({ "alt" }, "tab", nextWindow, nextWindow),
      previous = bindOrFail(
        { "alt", "shift" },
        "tab",
        previousWindow,
        previousWindow
      ),
    },
  }

  function controller.candidateCount(self)
    local filter = (type(self) == "table" and self.windowFilter) or windowFilter
    return #filter:getWindows()
  end

  function controller.next()
    nextWindow()
  end

  function controller.previous()
    previousWindow()
  end

  function controller.clickIndex(self, index)
    local actualIndex = index or self
    clickWindow(switcher, actualIndex)
  end

  function controller.cancel()
    dismissWithoutFocus(switcher)
    clearSession()
  end

  function controller.stop(self)
    dismissWithoutFocus(switcher)
    clearSession()
    local target = (type(self) == "table" and self) or controller
    for _, hotkey in pairs(target.hotkeys or {}) do
      hotkey:delete()
    end
    target.hotkeys = {}
    if windowFilter ~= nil then
      windowFilter:pause()
    end
  end

  return controller
end

return M
