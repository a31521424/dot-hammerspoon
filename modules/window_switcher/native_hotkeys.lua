local M = {}
local log = hs.logger.new("native-hotkeys", "warning")

function M.start(options)
  local directory = hs.configdir .. "/modules/window_switcher"
  local binary = directory .. "/native_guard"
  local source = binary .. ".swift"
  local journal = directory .. "/.native-hotkeys.json"
  local driver = { active = false, stopped = false, sessionActive = false }

  local function unavailable(message)
    driver.active = false
    driver.error = message
    if not driver.stopped then
      log.ef("%s; restoring system Command-Tab", message)
      if options.onUnavailable then options.onUnavailable() end
    end
  end

  local function recover(ownerPID)
    if ownerPID == nil then return end
    -- The journal includes its owner PID. A stale completion cannot restore
    -- over a replacement guardian that has already acquired a new lease.
    driver.restoreTask = hs.task.new(binary, function(code)
      driver.restoreTask = nil
      if code ~= 0 then log.ef("native hotkey recovery failed (%s)", code) end
    end, { "--restore", tostring(ownerPID), journal })
    if driver.restoreTask then driver.restoreTask:start() end
  end

  local function launch()
    if driver.stopped then return end
    local buffer = ""
    local task
    task = hs.task.new(binary, function(code)
      if driver.task ~= task then return end
      driver.task = nil
      driver.active = false
      recover(task:pid())
      if not driver.stopped then unavailable(driver.error or ("native hotkey helper exited (" .. code .. ")")) end
    end, function(current, stdout)
      if current == nil or driver.task ~= task or driver.stopped then return false end
      buffer = buffer .. (stdout or "")
      while true do
        local ending = buffer:find("\n", 1, true)
        if not ending then break end
        local line = buffer:sub(1, ending - 1)
        buffer = buffer:sub(ending + 1)
        local ok, event = pcall(hs.json.decode, line)
        if ok and type(event) == "table" then
          if event.event == "ready" then
            driver.active = true
            driver.original = event.original
          elseif event.event == "error" then
            driver.lastError = event
            unavailable(event.message or "native hotkey helper error")
          elseif driver.active then
            options.onAction(event)
          end
        end
      end
      return true
    end, { "--lease", tostring(hs.processInfo.processID), journal })
    driver.task = task
    if not task or not task:start() then
      driver.task = nil
      unavailable("could not launch native hotkey helper")
    end
  end

  function driver:setSessionActive(active, gesture)
    if active and gesture == nil then return end
    if self.sessionActive == active and self.sessionGesture == gesture then return end
    if self.active and self.task and self.task:isRunning() then
      local id = active and gesture or self.sessionGesture
      if id then self.task:setInput((active and "active " or "inactive ") .. id .. "\n") end
    end
    self.sessionActive = active
    self.sessionGesture = active and gesture or nil
  end

  function driver:stop()
    if self.stopped then return end
    self:setSessionActive(false)
    self.stopped = true
    self.active = false
    if self.compileTask then self.compileTask:terminate(); self.compileTask = nil end
    if self.task and self.task:isRunning() then
      -- SIGTERM restores on the helper's main loop. EOF and a parent-PID
      -- monitor also restore if Hammerspoon disappears without this callback.
      self.task:terminate()
    end
  end

  local sourceInfo = hs.fs.attributes(source)
  local binaryInfo = hs.fs.attributes(binary)
  if not sourceInfo then
    unavailable("native hotkey helper source is missing")
  elseif not binaryInfo or sourceInfo.modification > binaryInfo.modification then
    driver.compileTask = hs.task.new("/usr/bin/swiftc", function(code)
      driver.compileTask = nil
      if driver.stopped then return end
      if code == 0 then launch() else unavailable("native hotkey helper compilation failed") end
    end, { "-O", source, "-o", binary })
    if not driver.compileTask or not driver.compileTask:start() then
      driver.compileTask = nil
      unavailable("could not start Swift compiler")
    end
  else
    launch()
  end
  return driver
end

return M
