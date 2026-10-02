-- Read-only focus identity shared by delayed remote actions and voice output.
local M = {}

function M.capture()
  local app = hs.application.frontmostApplication()
  local win = hs.window.focusedWindow()
  local ok, element = pcall(function()
    return hs.axuielement.systemWideElement():attributeValue("AXFocusedUIElement")
  end)
  return {
    bundleID = app and app:bundleID(),
    pid = app and app:pid(),
    windowID = win and win:id(),
    element = ok and element or nil,
    navigationEpoch = RemoteControl and RemoteControl._state.navigationEpoch or 0,
    sessionLocked = RemoteControl and RemoteControl._state.sessionLocked or false,
  }
end

function M.matches(expected, actual, ignoreNavigation)
  if not expected or not actual or not expected.bundleID or not expected.windowID then return false end
  if actual.sessionLocked then return false end
  if expected.bundleID ~= actual.bundleID or expected.pid ~= actual.pid
      or expected.windowID ~= actual.windowID then return false end
  if expected.element ~= actual.element then return false end
  return ignoreNavigation or expected.navigationEpoch == actual.navigationEpoch
end

return M
