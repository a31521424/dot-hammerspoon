-- hs -c 'return dofile(hs.configdir .. "/tests/native_hotkeys_test.lua")'
local root = hs.configdir
local decode = hs.json.decode
local function fixture(files)
  local tasks, actions, failures = {}, {}, {}
  local fake = {
    configdir = root, processInfo = { processID = 1234 },
    logger = { new = function() return { ef = function() end } end },
    json = { decode = function(line)
      if line == "invalid" then error("malformed helper output") end
      return decode(line)
    end },
    fs = { attributes = function(path)
      return files[path:match("%.swift$") and "source" or "binary"]
    end },
    task = { new = function(path, complete, stream, args)
      if type(stream) == "table" then args, stream = stream, nil end
      local task = { path = path, complete = complete, stream = stream, args = args,
        inputs = {}, running = false, terminated = 0 }
      function task:start() self.running = true; return self end
      function task:pid() return 9000 + self.index end
      function task:isRunning() return self.running end
      function task:setInput(input) self.inputs[#self.inputs + 1] = input end
      function task:terminate() self.terminated = self.terminated + 1 end
      function task:finish(code) self.running = false; self.complete(code) end
      tasks[#tasks + 1] = task
      task.index = #tasks
      return task
    end },
  }
  local module = assert(loadfile(root .. "/modules/window_switcher/native_hotkeys.lua", "t",
    setmetatable({ hs = fake }, { __index = _G })))()
  local driver = module.start({ onAction = function(event) actions[#actions + 1] = event end,
    onUnavailable = function() failures[#failures + 1] = true end })
  return driver, tasks, actions, failures
end

local files = { source = { modification = 1 }, binary = { modification = 2 } }
local driver, tasks, actions, failures = fixture(files)
local guard = tasks[1]
assert(guard.args[1] == "--lease" and guard.args[2] == "1234")
guard.stream(guard, '{"event":"rea')
assert(not driver.active)
guard.stream(guard, 'dy","original":[true,false]}\ninvalid\n{"event":"next"}\n')
assert(driver.active and driver.original[1] and not driver.original[2])
assert(#actions == 1 and actions[1].event == "next")
driver:setSessionActive(true, 42)
driver:setSessionActive(true, 42)
driver:setSessionActive(false)
assert(#guard.inputs == 2 and guard.inputs[1] == "active 42\n" and guard.inputs[2] == "inactive 42\n")
guard:finish(9)
assert(not driver.active and #failures == 1)
assert(tasks[2].args[1] == "--restore" and tasks[2].args[2] == tostring(guard:pid()))
assert(guard.stream(nil, '{"event":"next"}\n') == false and #actions == 1)

driver, tasks, actions, failures = fixture(files)
guard = tasks[1]
guard.stream(guard, '{"event":"ready"}\n')
driver:stop()
driver:stop()
assert(guard.terminated == 1 and not driver.active)
assert(not guard.stream(guard, '{"event":"next"}\n') and #actions == 0)
guard:finish(0)
assert(#failures == 0 and tasks[2].args[1] == "--restore")

driver, tasks, actions, failures = fixture({ source = { modification = 3 } })
assert(tasks[1].path == "/usr/bin/swiftc")
tasks[1]:finish(0)
assert(tasks[2].args[1] == "--lease")
driver:stop()

driver, tasks, actions, failures = fixture({ source = { modification = 3 } })
driver:stop()
tasks[1]:finish(0)
assert(#tasks == 1 and tasks[1].terminated == 1)

driver, tasks, actions, failures = fixture({ source = { modification = 3 } })
tasks[1]:finish(1)
assert(not driver.active and #tasks == 1 and #failures == 1)
driver, tasks, actions, failures = fixture({})
assert(#tasks == 0 and #failures == 1)
return "PASS: native helper streaming, session commands, crash recovery, stop and compilation lifecycle"
