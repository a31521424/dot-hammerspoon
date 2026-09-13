-- Hold-to-talk voice input for Hammerspoon.
--
-- Hold Option + W to listen. A preview card shows the full transcript
-- and can be rewritten as recognition revises earlier words. Releasing
-- the key stops recording; after leftover API calls finish, the preview
-- closes and the complete text is pasted at the caret.
local M = {}

local log = hs.logger.new("voice-input", "debug")
local API_KEY_ENV = "HAMMERSPOON_VOICE_DOUBAO_API_KEY"
local DEBUG = true
local DEBUG_LOG = (hs.configdir or os.getenv("HOME") .. "/.hammerspoon")
  .. "/voice_input_debug.log"

local function previewText(text)
  if text == nil or text == "" then
    return ""
  end
  if #text > 36 then
    return text:sub(1, 36) .. "…"
  end
  return text
end

local function dbg(fmt, ...)
  if not DEBUG then
    return
  end
  local ok, text = pcall(string.format, fmt, ...)
  if not ok then
    text = tostring(fmt)
  end
  local line = string.format("%.3f %s\n", hs.timer.secondsSinceEpoch(), text)
  local file = io.open(DEBUG_LOG, "a")
  if file ~= nil then
    file:write(line)
    file:close()
  end
  log.d(text)
end

local function resetDebugLog()
  local file = io.open(DEBUG_LOG, "w")
  if file ~= nil then
    file:write("voice-input debug log\n")
    file:close()
  end
end

local SAMPLE_RATE = 16000
local CHANNELS = 1
local BYTES_PER_SAMPLE = 2
local BYTES_PER_SECOND = SAMPLE_RATE * CHANNELS * BYTES_PER_SAMPLE
local MIN_PCM_BYTES = BYTES_PER_SECOND * 0.4
local SEGMENT_SECONDS = 0.1
local LIVE_INTERVAL = 0.5
local FORCE_WINDOW_SECONDS = 20
local SILENCE_WINDOW_SECONDS = 3.2
local SILENCE_TAIL_SECONDS = 0.35
local SILENCE_LEVEL = 0.07
local FLIGHT_TIMEOUT = 7
local QUERY_INTERVAL = 0.8
local QUERY_TIMEOUT = 45
local MAX_RECORD_SECONDS = 120

local DEFAULT_FLASH_URL = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"
local DEFAULT_SUBMIT_URL = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit"
local DEFAULT_QUERY_URL = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/query"
local DEFAULT_RESOURCE_ID = "volc.seedasr.auc"

local function listAudioDevices(ffmpeg)
  local command = string.format(
    "'%s' -hide_banner -f avfoundation -list_devices true -i '' 2>&1",
    ffmpeg
  )
  local output = hs.execute(command)
  local devices = {}
  local inAudio = false
  for line in (output or ""):gmatch("[^\n]+") do
    if line:find("AVFoundation audio devices", 1, true) then
      inAudio = true
    elseif line:find("AVFoundation video devices", 1, true) then
      inAudio = false
    elseif inAudio then
      local index, name = line:match("%[(%d+)%]%s+(.+)")
      if index ~= nil then
        devices[#devices + 1] = { index = index, name = name }
      end
    end
  end
  return devices
end

local function pickAudioDevice(ffmpeg, preferred)
  if preferred ~= nil and preferred ~= "" then
    return preferred
  end

  local best = nil
  local bestScore = -1
  for _, device in ipairs(listAudioDevices(ffmpeg)) do
    local name = device.name or ""
    local score = 3
    if name:find("BlackHole", 1, true) or name:find("Virtual", 1, true) then
      score = 0
    elseif name:find("iPhone", 1, true) then
      score = 1
    elseif name:find("MacBook", 1, true) or name:find("Built%-in") then
      score = 10
    elseif name:find("麦克风") or name:find("Microphone") then
      score = 5
    end
    if score > bestScore then
      best = device
      bestScore = score
    end
  end
  if best == nil then
    return ":0"
  end
  return ":" .. best.index
end

local function executable(paths)
  for _, path in ipairs(paths) do
    if hs.fs.attributes(path, "mode") == "file" then
      return path
    end
  end
  return nil
end

local function resolveApiKey(explicit)
  if explicit ~= nil and explicit ~= "" then
    return explicit
  end
  local inherited = os.getenv(API_KEY_ENV)
  if inherited ~= nil and inherited ~= "" then
    return inherited
  end

  -- GUI-launched Hammerspoon usually does not inherit ~/.zshrc. Ask an
  -- interactive login shell as a fallback so the key can live there.
  local output, status = hs.execute(
    "printf '%s' \"$HAMMERSPOON_VOICE_DOUBAO_API_KEY\"",
    true
  )
  if status and output ~= nil then
    output = output:gsub("%s+$", "")
    if output ~= "" then
      return output
    end
  end
  return nil
end

local function u32le(value)
  value = math.floor(value) % 4294967296
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

local function u16le(value)
  value = math.floor(value) % 65536
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function pcmToWav(pcm)
  local dataSize = #pcm
  local byteRate = SAMPLE_RATE * CHANNELS * BYTES_PER_SAMPLE
  local blockAlign = CHANNELS * BYTES_PER_SAMPLE
  return "RIFF"
    .. u32le(36 + dataSize)
    .. "WAVEfmt "
    .. u32le(16)
    .. u16le(1)
    .. u16le(CHANNELS)
    .. u32le(SAMPLE_RATE)
    .. u32le(byteRate)
    .. u16le(blockAlign)
    .. u16le(16)
    .. "data"
    .. u32le(dataSize)
    .. pcm
end

local function tempSegmentDir()
  local path = hs.fs.temporaryDirectory() .. "hammerspoon-voice-" .. hs.host.uuid()
  hs.fs.mkdir(path)
  return path
end

local function removeDir(path)
  if path == nil then
    return
  end
  for name in hs.fs.dir(path) do
    if name ~= "." and name ~= ".." then
      os.remove(path .. "/" .. name)
    end
  end
  hs.fs.rmdir(path)
end

local function listWavs(dir)
  local files = {}
  if dir == nil then
    return files
  end
  for name in hs.fs.dir(dir) do
    if type(name) == "string" and name:match("%.wav$") then
      files[#files + 1] = dir .. "/" .. name
    end
  end
  table.sort(files)
  return files
end

local function readFile(path)
  if path == nil then
    return ""
  end
  local file = io.open(path, "rb")
  if file == nil then
    return ""
  end
  local data = file:read("*a") or ""
  file:close()
  return data
end

local function wavPcm(data)
  if data == nil or #data < 44 then
    return ""
  end
  local pos = data:find("data", 1, true)
  if pos == nil or pos + 8 > #data then
    return ""
  end
  return data:sub(pos + 8)
end

local function pcmTail(pcm, seconds)
  local bytes = math.floor(BYTES_PER_SECOND * seconds)
  if pcm == nil or pcm == "" then
    return ""
  end
  if #pcm <= bytes then
    return pcm
  end
  return pcm:sub(#pcm - bytes + 1)
end

local function headerValue(headers, name)
  if type(headers) ~= "table" then
    return nil
  end
  local wanted = name:lower()
  for key, value in pairs(headers) do
    if type(key) == "string" and key:lower() == wanted then
      return value
    end
  end
  return nil
end

local function decodeJson(payload)
  if payload == nil or payload == "" then
    return nil
  end
  local ok, decoded = pcall(hs.json.decode, payload)
  if ok then
    return decoded
  end
  return nil
end

local function findText(value)
  if type(value) ~= "table" then
    return nil
  end
  if type(value.text) == "string" and value.text ~= "" then
    return value.text
  end
  if value.result ~= nil then
    local text = findText(value.result)
    if text ~= nil then
      return text
    end
  end
  for _, item in ipairs(value) do
    local text = findText(item)
    if text ~= nil then
      return text
    end
  end
  return nil
end

local function describeStatus(code, message)
  code = tostring(code or "")
  message = message or ""
  if code == "401" or message:find("401", 1, true) then
    return "Voice request failed: 401 Unauthorized. Check HAMMERSPOON_VOICE_DOUBAO_API_KEY"
  end
  if code == "403" or message:find("403", 1, true) then
    return "Voice request failed: 403 Forbidden. Open Doubao file ASR (volc.seedasr.auc) for this key"
  end
  if code == "20000003" then
    return "Voice request failed: no speech detected"
  end
  if message ~= "" then
    return "Voice request failed: " .. message
  end
  if code ~= "" then
    return "Voice request failed: " .. code
  end
  return "Voice request failed"
end

local function audioLevel(data)
  if #data < 2 then
    return 0
  end

  local sum = 0
  local peak = 0
  local samples = math.floor(#data / 2)
  local step = 1
  if samples > 640 then
    step = math.floor(samples / 640)
  end
  local count = 0
  for index = 1, samples, step do
    local offset = (index - 1) * 2
    local lo, hi = string.byte(data, offset + 1, offset + 2)
    local sample = lo + (hi * 256)
    if sample >= 32768 then
      sample = sample - 65536
    end
    local abs = math.abs(sample)
    if abs > peak then
      peak = abs
    end
    sum = sum + (sample * sample)
    count = count + 1
  end

  local rms = math.sqrt(sum / count)
  return math.min(1, math.max(rms / 1100, peak / 4200))
end

local function visualColumns(text)
  local width = 0
  if utf8 ~= nil and utf8.codes ~= nil then
    for _, code in utf8.codes(text) do
      if code == 9 then
        width = width + 4
      elseif code >= 32 and code < 127 then
        width = width + 0.55
      elseif code >= 32 then
        width = width + 1
      end
    end
    return width
  end
  return #text
end

local function wrappedTextHeight(text, columns, lineHeight)
  local lines = 0
  local source = text
  if source == nil or source == "" then
    source = " "
  end
  if source:sub(-1) ~= "\n" then
    source = source .. "\n"
  end
  for paragraph in source:gmatch("(.-)\n") do
    local used = math.ceil(visualColumns(paragraph) / columns)
    if used < 1 then
      used = 1
    end
    lines = lines + used
  end
  if lines < 1 then
    lines = 1
  end
  return lines * lineHeight
end

local function makeUI()
  local ui = {
    canvas = nil,
    bars = {},
    width = 560,
    height = 96,
    padding = 22,
    headerH = 68,
    barWidth = 4.5,
    barStep = 11,
    textSize = 15,
    status = "正在听",
    transcript = "",
    finishing = false,
    visible = false,
    lastLevel = 0,
  }

  ui.canvas = hs.canvas.new({ x = 0, y = 0, w = ui.width, h = ui.height })
  ui.canvas:level("screenSaver")
  ui.canvas:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "ignoresCycle" })
  pcall(function()
    ui.canvas:clickActivating(false)
  end)
  ui.canvas:appendElements({
    {
      type = "rectangle",
      action = "fill",
      roundedRectRadii = { xRadius = 22, yRadius = 22 },
      fillColor = { red = 0.035, green = 0.042, blue = 0.07, alpha = 0.94 },
      frame = { x = 0, y = 0, w = ui.width, h = ui.height },
    },
    {
      type = "rectangle",
      action = "stroke",
      roundedRectRadii = { xRadius = 22, yRadius = 22 },
      strokeColor = { red = 1, green = 1, blue = 1, alpha = 0.10 },
      strokeWidth = 1,
      frame = { x = 0.5, y = 0.5, w = ui.width - 1, h = ui.height - 1 },
    },
  })
  ui.bg = 1
  ui.border = 2

  for index = 1, 9 do
    ui.canvas:appendElements({
      type = "rectangle",
      action = "fill",
      fillColor = { red = 0.38, green = 0.74, blue = 1, alpha = 0.95 },
      roundedRectRadii = { xRadius = 2.5, yRadius = 2.5 },
      frame = { x = 234 + ((index - 1) * 11), y = 16, w = 4.5, h = 8 },
    })
    ui.bars[index] = 2 + index
  end

  ui.canvas:appendElements({
    {
      type = "text",
      text = "正在听",
      textSize = 13,
      textFont = ".AppleSystemUIFont",
      textColor = { red = 0.78, green = 0.84, blue = 0.94, alpha = 0.92 },
      textAlignment = "center",
      frame = { x = 22, y = 40, w = 516, h = 20 },
    },
    {
      type = "rectangle",
      action = "fill",
      fillColor = { red = 1, green = 1, blue = 1, alpha = 0.07 },
      frame = { x = 22, y = 52, w = 516, h = 1 },
    },
    {
      type = "text",
      text = "识别结果会显示在这里",
      textSize = ui.textSize,
      textFont = ".AppleSystemUIFont",
      textColor = { red = 0.62, green = 0.68, blue = 0.78, alpha = 0.88 },
      textLineBreak = "wordWrap",
      frame = { x = 22, y = 64, w = 516, h = 24 },
    },
  })
  ui.statusEl = 12
  ui.divider = 13
  ui.bodyEl = 14
  ui.canvas:hide()

  local function screenFrame()
    local win = hs.window.focusedWindow()
    local screen = (win ~= nil and win:screen()) or hs.screen.mainScreen()
    return screen:frame()
  end

  function ui:layout()
    local screen = screenFrame()
    local width = math.min(640, math.max(440, math.floor(screen.w * 0.44)))
    self.width = width
    local inner = width - (self.padding * 2)
    local display = self.transcript
    local placeholder = display == nil or display == ""
    if placeholder then
      if self.finishing then
        display = "正在完成识别…"
      else
        display = "识别结果会显示在这里"
      end
    end
    local columns = inner / self.textSize
    if columns < 12 then
      columns = 12
    end
    local bodyHeight = wrappedTextHeight(display, columns, 22)
    local maxBody = math.min(360, math.max(80, math.floor(screen.h * 0.38)))
    if bodyHeight > maxBody then
      bodyHeight = maxBody
    end
    self.height = self.headerH + bodyHeight + self.padding
    local frame = {
      x = math.floor(screen.x + ((screen.w - self.width) / 2)),
      y = screen.y + 16,
      w = self.width,
      h = self.height,
    }
    self.canvas:frame(frame)
    self.canvas:elementAttribute(self.bg, "frame", {
      x = 0, y = 0, w = self.width, h = self.height,
    })
    self.canvas:elementAttribute(self.border, "frame", {
      x = 0.5, y = 0.5, w = self.width - 1, h = self.height - 1,
    })
    self.canvas:elementAttribute(self.statusEl, "frame", {
      x = self.padding, y = 40, w = inner, h = 20,
    })
    self.canvas:elementAttribute(self.statusEl, "textAlignment", "center")
    self.canvas:elementAttribute(self.statusEl, "text", self.status)
    self:placeBars(self.lastLevel)
    self.canvas:elementAttribute(self.divider, "frame", {
      x = self.padding, y = self.headerH, w = inner, h = 1,
    })
    self.canvas:elementAttribute(self.bodyEl, "frame", {
      x = self.padding,
      y = self.headerH + 12,
      w = inner,
      h = bodyHeight,
    })
    self.canvas:elementAttribute(self.bodyEl, "text", display)
    if placeholder then
      self.canvas:elementAttribute(self.bodyEl, "textColor", {
        red = 0.62, green = 0.68, blue = 0.78, alpha = 0.88,
      })
    else
      self.canvas:elementAttribute(self.bodyEl, "textColor", {
        red = 0.93, green = 0.95, blue = 0.98, alpha = 0.98,
      })
    end
  end

  function ui:setStatus(text)
    self.status = text
    if self.visible then
      self.canvas:elementAttribute(self.statusEl, "text", text)
    end
  end

  function ui:setLabel(text)
    self:setStatus(text)
  end

  function ui:setFinishing(finishing)
    self.finishing = finishing and true or false
  end

  function ui:setTranscript(text)
    self.transcript = text or ""
    if self.visible then
      self:layout()
    end
  end

  function ui:barClusterWidth()
    return ((#self.bars - 1) * self.barStep) + self.barWidth
  end

  function ui:placeBars(level)
    if level == nil then
      level = self.lastLevel or 0
    else
      self.lastLevel = level
    end
    local now = hs.timer.secondsSinceEpoch()
    local left = math.floor((self.width - self:barClusterWidth()) / 2)
    local mid = 22
    for index, elementIndex in ipairs(self.bars) do
      local distance = math.abs(index - 5)
      local variation = 0.42 + (0.58 * math.abs(math.sin((now * 18) + (index * 1.1))))
      local height = math.max(4, math.floor(4 + (level * 34 * variation) - (distance * 1.0)))
      if height > 26 then
        height = 26
      end
      self.canvas:elementAttribute(elementIndex, "frame", {
        x = left + ((index - 1) * self.barStep),
        y = math.floor(mid - (height / 2)),
        w = self.barWidth,
        h = height,
      })
    end
  end

  function ui:setLevel(level)
    self:placeBars(level)
  end

  function ui:show()
    self.visible = true
    self:layout()
    self.canvas:show()
    self.canvas:bringToFront(true)
  end

  function ui:hide()
    self.visible = false
    self.canvas:hide()
  end

  return ui
end

local function insertAtCaret(text)
  if text == nil or text == "" then
    return
  end
  local saved = nil
  local ok, data = pcall(hs.pasteboard.readAllData)
  if ok then
    saved = data
  end
  hs.pasteboard.clearContents()
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({ "cmd" }, "v", 30000)
  hs.timer.doAfter(0.45, function()
    if saved ~= nil then
      pcall(hs.pasteboard.writeAllData, saved)
    end
  end)
end

local function afterModifiersClear(callback)
  local tries = 0
  local function check()
    local mods = hs.eventtap.checkKeyboardModifiers()
    if not mods.alt or tries >= 20 then
      callback()
      return
    end
    tries = tries + 1
    hs.timer.doAfter(0.05, check)
  end
  check()
end

local function requestBody(wavBytes)
  return hs.json.encode({
    user = { uid = "hammerspoon-voice-input" },
    audio = {
      data = hs.base64.encode(wavBytes),
      format = "wav",
      codec = "raw",
      rate = SAMPLE_RATE,
      bits = 16,
      channel = CHANNELS,
    },
    request = {
      model_name = "bigmodel",
      enable_itn = true,
      enable_punc = true,
      enable_ddc = false,
      enable_speaker_info = false,
      enable_channel_split = false,
      show_utterances = false,
      vad_segment = false,
      sensitive_words_filter = "",
    },
  })
end

local function recognizeFlash(options, wavBytes, callback)
  local apiKey = options.apiKey
  local resourceID = options.resourceID or DEFAULT_RESOURCE_ID
  local flashURL = options.flashURL or DEFAULT_FLASH_URL
  local requestID = hs.host.uuid()

  hs.http.asyncPost(flashURL, requestBody(wavBytes), {
    ["Content-Type"] = "application/json",
    ["X-Api-Key"] = apiKey,
    ["X-Api-Resource-Id"] = resourceID,
    ["X-Api-Request-Id"] = requestID,
    ["X-Api-Sequence"] = "-1",
  }, function(status, body, headers)
    if status < 0 then
      dbg("flash transport_error status=%s body=%s", tostring(status), tostring(body))
      callback(body or "recognize failed", nil)
      return
    end
    local code = headerValue(headers, "X-Api-Status-Code")
    local message = headerValue(headers, "X-Api-Message")
    if code == "20000003" then
      dbg("flash silence http=%s code=%s", tostring(status), tostring(code))
      callback(nil, "")
      return
    end
    if status ~= 200 or code ~= "20000000" then
      dbg("flash error http=%s code=%s msg=%s", tostring(status), tostring(code), tostring(message))
      callback(describeStatus(code or status, message or body), nil)
      return
    end
    local text = findText(decodeJson(body)) or ""
    dbg("flash ok http=%s text_len=%d preview=%s", tostring(status), #text, previewText(text))
    callback(nil, text)
  end)
end

local function recognizeWav(options, wavBytes, callback)
  local apiKey = options.apiKey
  local resourceID = options.resourceID or DEFAULT_RESOURCE_ID
  local submitURL = options.submitURL or DEFAULT_SUBMIT_URL
  local queryURL = options.queryURL or DEFAULT_QUERY_URL
  local requestID = hs.host.uuid()

  local function queryHeaders(logID)
    local headers = {
      ["Content-Type"] = "application/json",
      ["X-Api-Key"] = apiKey,
      ["X-Api-Resource-Id"] = resourceID,
      ["X-Api-Request-Id"] = requestID,
    }
    if logID ~= nil and logID ~= "" then
      headers["X-Tt-Logid"] = logID
    end
    return headers
  end

  hs.http.asyncPost(submitURL, requestBody(wavBytes), {
    ["Content-Type"] = "application/json",
    ["X-Api-Key"] = apiKey,
    ["X-Api-Resource-Id"] = resourceID,
    ["X-Api-Request-Id"] = requestID,
    ["X-Api-Sequence"] = "-1",
  }, function(status, body, headers)
    if status < 0 then
      callback(body or "submit failed", nil)
      return
    end
    local code = headerValue(headers, "X-Api-Status-Code")
    local message = headerValue(headers, "X-Api-Message")
    if status ~= 200 or code ~= "20000000" then
      callback(describeStatus(code or status, message or body), nil)
      return
    end

    local logID = headerValue(headers, "X-Tt-Logid")
    local deadline = hs.timer.secondsSinceEpoch() + QUERY_TIMEOUT
    local query

    query = function()
      hs.http.asyncPost(queryURL, "{}", queryHeaders(logID), function(qStatus, qBody, qHeaders)
        if qStatus < 0 then
          callback(qBody or "query failed", nil)
          return
        end
        local qCode = headerValue(qHeaders, "X-Api-Status-Code")
        local qMessage = headerValue(qHeaders, "X-Api-Message")
        if qCode == "20000000" then
          callback(nil, findText(decodeJson(qBody)) or "")
          return
        end
        if qCode == "20000001" or qCode == "20000002" then
          if hs.timer.secondsSinceEpoch() >= deadline then
            callback("Voice request failed: recognition timed out", nil)
            return
          end
          hs.timer.doAfter(QUERY_INTERVAL, query)
          return
        end
        if qCode == "20000003" then
          callback(nil, "")
          return
        end
        callback(describeStatus(qCode or qStatus, qMessage or qBody), nil)
      end)
    end

    query()
  end)
end

function M.start(options)
  options = options or {}
  local state = {
    generation = 0,
    active = false,
    stopping = false,
    failed = false,
    inFlight = false,
    pendingFinal = false,
    finalStarted = false,
    autoPaste = options.autoPaste ~= false,
    apiKey = resolveApiKey(options.apiKey),
    resourceID = options.resourceID or DEFAULT_RESOURCE_ID,
    flashURL = options.flashURL or DEFAULT_FLASH_URL,
    submitURL = options.submitURL or DEFAULT_SUBMIT_URL,
    queryURL = options.queryURL or DEFAULT_QUERY_URL,
    ffmpeg = options.ffmpegPath or executable({ "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg" }),
    audioDevice = options.audioDevice,
    audioTask = nil,
    segmentDir = nil,
    audioError = "",
    lastResult = "",
    sessionText = "",
    utteranceCommitted = "",
    pcmBuffer = "",
    ingested = {},
    windowStart = 0,
    submittedBytes = 0,
    pendingRoll = false,
    flightStarted = 0,
    level = 0,
    levelTimer = nil,
    liveTimer = nil,
    ui = makeUI(),
  }

  local function stopTimers()
    if state.levelTimer ~= nil then
      state.levelTimer:stop()
      state.levelTimer = nil
    end
    if state.liveTimer ~= nil then
      state.liveTimer:stop()
      state.liveTimer = nil
    end
  end

  local function cleanupCapture()
    removeDir(state.segmentDir)
    state.segmentDir = nil
    state.pcmBuffer = ""
    state.ingested = {}
  end

  local function fail(message)
    if state.failed then
      return
    end
    local showPreview = state.active or state.stopping or (state.ui ~= nil and state.ui.visible)
    state.failed = true
    state.active = false
    state.stopping = false
    state.inFlight = false
    state.pendingFinal = false
    log.e(message)
    stopTimers()
    if state.audioTask ~= nil and state.audioTask:isRunning() then
      local pid = state.audioTask:pid()
      if pid ~= nil then
        hs.execute("/bin/kill -9 " .. tostring(pid))
      else
        state.audioTask:terminate()
      end
    end
    cleanupCapture()
    if showPreview and state.ui ~= nil then
      state.ui:setFinishing(true)
      state.ui:setStatus("识别出错")
      state.ui:setTranscript(message)
      state.ui:show()
      hs.timer.doAfter(1.6, function()
        if not state.active then
          state.ui:hide()
        end
      end)
    elseif message:find("401", 1, true) or message:find("403", 1, true) then
      hs.alert.show(message, 2)
    end
  end

  local function sessionTranscript()
    return state.sessionText .. state.utteranceCommitted
  end

  local function refreshPreview()
    if state.ui == nil then
      return
    end
    state.ui:setTranscript(sessionTranscript())
  end

  local function applyTranscript(text)
    if text == nil or text == "" then
      return
    end
    dbg("apply preview session_len=%d window_len=%d text_len=%d preview=%s",
      #state.sessionText, #state.utteranceCommitted, #text, previewText(text))
    state.utteranceCommitted = text
    state.lastResult = sessionTranscript()
    refreshPreview()
  end

  local function ingestSegments(includeLast)
    if state.segmentDir == nil then
      return
    end
    local files = listWavs(state.segmentDir)
    local last = #files
    local added = 0
    for index, path in ipairs(files) do
      if not state.ingested[path] and (includeLast or index < last) then
        local pcm = wavPcm(readFile(path))
        if #pcm >= 64 then
          state.pcmBuffer = state.pcmBuffer .. pcm
          state.ingested[path] = true
          added = added + 1
        end
      end
    end
    if added > 0 then
      dbg("ingest +%d files total_files=%d pcm_bytes=%d include_last=%s",
        added, last, #state.pcmBuffer, tostring(includeLast))
    end
  end

  local function windowPcm()
    if state.windowStart >= #state.pcmBuffer then
      return ""
    end
    return state.pcmBuffer:sub(state.windowStart + 1)
  end

  local function rollWindow()
    local beforeStart = state.windowStart
    local beforeSubmitted = state.submittedBytes
    state.sessionText = state.sessionText .. state.utteranceCommitted
    state.utteranceCommitted = ""
    local recognized = state.windowStart + state.submittedBytes
    if recognized < state.windowStart then
      recognized = state.windowStart
    end
    if recognized > #state.pcmBuffer then
      recognized = #state.pcmBuffer
    end
    state.windowStart = recognized
    state.submittedBytes = 0
    state.pendingRoll = false
    dbg("roll start %d->%d submitted=%d pcm=%d session_len=%d",
      beforeStart, state.windowStart, beforeSubmitted, #state.pcmBuffer, #state.sessionText)
  end

  local function shouldRoll(pcm)
    if #pcm >= FORCE_WINDOW_SECONDS * BYTES_PER_SECOND then
      return true
    end
    if #pcm >= SILENCE_WINDOW_SECONDS * BYTES_PER_SECOND then
      return audioLevel(pcmTail(pcm, SILENCE_TAIL_SECONDS)) <= SILENCE_LEVEL
    end
    return false
  end

  local function finishSession()
    local gen = state.generation
    local text = sessionTranscript()
    state.active = false
    state.stopping = false
    state.inFlight = false
    state.pendingFinal = false
    state.finalStarted = false
    stopTimers()
    cleanupCapture()
    if state.ui ~= nil then
      state.ui:hide()
    end
    dbg("finish gen=%d text_len=%d preview=%s", gen, #text, previewText(text))
    if not state.autoPaste or text == "" then
      return
    end
    afterModifiersClear(function()
      if state.generation ~= gen then
        return
      end
      dbg("insert caret text_len=%d preview=%s", #text, previewText(text))
      insertAtCaret(text)
    end)
  end

  local function recognizePcm(pcm, final, gen)
    gen = gen or state.generation
    if state.generation ~= gen then
      dbg("recognize skip_gen final=%s", tostring(final))
      return
    end
    if state.inFlight then
      local waited = hs.timer.secondsSinceEpoch() - state.flightStarted
      if waited > FLIGHT_TIMEOUT then
        dbg("recognize inflight_timeout waited=%.2f", waited)
        state.inFlight = false
      elseif final then
        dbg("recognize queue_final inflight waited=%.2f", waited)
        state.pendingFinal = true
        return
      else
        dbg("recognize skip_inflight waited=%.2f pcm=%d submitted=%d", waited, #pcm, state.submittedBytes)
        return
      end
    end
    if state.failed then
      dbg("recognize skip_failed")
      return
    end
    if #pcm < MIN_PCM_BYTES then
      dbg("recognize skip_short pcm=%d final=%s", #pcm, tostring(final))
      if final then
        finishSession()
      end
      return
    end
    if not final and #pcm <= state.submittedBytes then
      dbg("recognize skip_no_new pcm=%d submitted=%d", #pcm, state.submittedBytes)
      return
    end

    local captureDir = state.segmentDir
    state.inFlight = true
    state.flightStarted = hs.timer.secondsSinceEpoch()
    dbg("recognize send pcm=%d final=%s window_start=%d", #pcm, tostring(final), state.windowStart)
    recognizeFlash({
      apiKey = state.apiKey,
      resourceID = state.resourceID,
      flashURL = state.flashURL,
    }, pcmToWav(pcm), function(err, text)
      if state.generation ~= gen then
        if captureDir ~= nil and captureDir ~= state.segmentDir then
          removeDir(captureDir)
        end
        return
      end
      state.inFlight = false
      if state.failed then
        return
      end
      if err ~= nil then
        dbg("recognize recv_error final=%s err=%s", tostring(final), tostring(err))
        if not final then
          state.submittedBytes = #pcm
          if shouldRoll(pcm) then
            rollWindow()
          end
          return
        end
        if sessionTranscript() ~= "" then
          finishSession()
          return
        end
        fail(err)
        return
      end
      dbg("recognize recv_ok final=%s text_len=%d", tostring(final), #(text or ""))
      applyTranscript(text)
      state.submittedBytes = #pcm
      if state.pendingRoll and not state.stopping then
        rollWindow()
      end
      if state.pendingFinal and state.stopping then
        state.pendingFinal = false
        ingestSegments(true)
        local latest = windowPcm()
        if #latest > MIN_PCM_BYTES and #latest > state.submittedBytes then
          recognizePcm(latest, true, gen)
        else
          finishSession()
        end
        return
      end
      if final then
        finishSession()
      end
    end)
  end

  local function liveTick()
    if not state.active or state.failed or state.stopping then
      dbg("live skip active=%s failed=%s stopping=%s",
        tostring(state.active), tostring(state.failed), tostring(state.stopping))
      return
    end
    ingestSegments(false)
    local pcm = windowPcm()
    local roll = shouldRoll(pcm)
    dbg("live pcm=%d window_start=%d submitted=%d inflight=%s roll=%s utter_len=%d",
      #pcm, state.windowStart, state.submittedBytes, tostring(state.inFlight),
      tostring(roll), #state.utteranceCommitted)
    if roll and state.utteranceCommitted ~= "" then
      if state.inFlight then
        state.pendingRoll = true
        dbg("live pending_roll")
      else
        rollWindow()
        pcm = windowPcm()
      end
    end
    recognizePcm(pcm, false, state.generation)
  end

  local function finalize()
    if state.failed or state.finalStarted then
      dbg("finalize skip failed=%s started=%s", tostring(state.failed), tostring(state.finalStarted))
      return
    end
    state.finalStarted = true
    ingestSegments(true)
    dbg("finalize pcm=%d", #windowPcm())
    recognizePcm(windowPcm(), true, state.generation)
  end

  local function stop()
    if not state.active or state.stopping then
      return
    end
    local gen = state.generation
    dbg("stop gen=%d pcm=%d preview_len=%d", gen, #state.pcmBuffer, #sessionTranscript())
    state.active = false
    state.stopping = true
    if state.liveTimer ~= nil then
      state.liveTimer:stop()
      state.liveTimer = nil
    end
    if state.ui ~= nil then
      state.ui:setFinishing(true)
      state.ui:setStatus("正在完成识别")
      refreshPreview()
    end
    if state.audioTask ~= nil and state.audioTask:isRunning() then
      local pid = state.audioTask:pid()
      if pid ~= nil then
        hs.execute("/bin/kill -9 " .. tostring(pid))
      else
        state.audioTask:terminate()
      end
    end
    hs.timer.doAfter(0.28, function()
      if state.generation == gen then
        finalize()
      end
    end)
  end

  local function start()
    if state.active then
      dbg("start ignored already_active")
      return
    end
    if state.audioTask ~= nil and state.audioTask:isRunning() then
      local pid = state.audioTask:pid()
      if pid ~= nil then
        hs.execute("/bin/kill -9 " .. tostring(pid))
      end
    end
    stopTimers()
    local previousDir = state.segmentDir
    local previousInFlight = state.inFlight
    state.generation = state.generation + 1
    if previousDir ~= nil and not previousInFlight then
      removeDir(previousDir)
    end
    state.failed = false
    state.apiKey = resolveApiKey(state.apiKey)
    if state.apiKey == nil or state.apiKey == "" then
      fail("Set HAMMERSPOON_VOICE_DOUBAO_API_KEY first")
      return
    end
    if state.ffmpeg == nil then
      fail("Install ffmpeg first")
      return
    end

    state.active = true
    state.stopping = false
    state.inFlight = false
    state.pendingFinal = false
    state.finalStarted = false
    state.lastResult = ""
    state.sessionText = ""
    state.utteranceCommitted = ""
    state.pcmBuffer = ""
    state.ingested = {}
    state.windowStart = 0
    state.submittedBytes = 0
    state.pendingRoll = false
    state.flightStarted = 0
    state.segmentDir = tempSegmentDir()
    state.audioError = ""
    state.level = 0
    state.ui:setFinishing(false)
    state.ui:setStatus("正在听")
    state.ui:setTranscript("")
    state.ui:setLevel(0)
    state.ui:show()

    -- hs.task cannot stream binary PCM, and a single s16le/wav file is not
    -- flushed until ffmpeg exits cleanly. Short WAV segments survive stop.
    if state.captureDevice == nil then
      state.captureDevice = pickAudioDevice(state.ffmpeg, state.audioDevice)
    end
    local audioArgs = {
      "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
      "-f", "avfoundation", "-i", state.captureDevice,
      "-ac", tostring(CHANNELS), "-ar", tostring(SAMPLE_RATE),
      "-c:a", "pcm_s16le",
      "-t", tostring(MAX_RECORD_SECONDS),
      "-f", "segment", "-segment_time", tostring(SEGMENT_SECONDS),
      "-reset_timestamps", "1",
      state.segmentDir .. "/out%03d.wav",
    }
    state.audioTask = hs.task.new(state.ffmpeg, function(code, _, stderr)
      if stderr ~= nil and stderr ~= "" then
        state.audioError = (state.audioError .. " " .. stderr)
          :gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      end
      if state.failed then
        return
      end
      if code ~= 0 and state.active and not state.stopping then
        fail("Microphone capture failed: " .. (state.audioError ~= "" and state.audioError or "ffmpeg error"))
        return
      end
      if state.stopping then
        finalize()
      end
    end, function(_, _, stderr)
      if stderr ~= nil and stderr ~= "" then
        state.audioError = state.audioError .. " " .. stderr
        log.w("ffmpeg: " .. stderr)
      end
      return true
    end, audioArgs)
    if not state.audioTask:start() then
      fail("Could not start microphone capture")
      return
    end
    dbg("start gen=%d device=%s", state.generation, tostring(state.captureDevice))

    state.levelTimer = hs.timer.doEvery(0.04, function()
      if state.failed or (not state.active and not state.stopping) then
        return
      end
      if state.stopping then
        local pulse = 0.16 + (0.14 * math.abs(math.sin(hs.timer.secondsSinceEpoch() * 3.2)))
        state.ui:setLevel(pulse)
        return
      end
      ingestSegments(false)
      local pcm = pcmTail(state.pcmBuffer, 0.28)
      local measured = 0
      if pcm ~= "" then
        measured = audioLevel(pcm)
      end
      if measured > state.level then
        state.level = measured
      else
        state.level = state.level * 0.52
      end
      state.ui:setLevel(state.level)
    end)

    state.liveTimer = hs.timer.doEvery(LIVE_INTERVAL, liveTick)
    hs.timer.doAfter(0.45, liveTick)
  end

  -- Option + W is a real USB combo on 68-key boards. Eating the
  -- event also blocks the Option+W special character (∑).
  local talkKey = hs.keycodes.map.w or 13
  state.eventtap = hs.eventtap.new({
    hs.eventtap.event.types.keyDown,
    hs.eventtap.event.types.keyUp,
    hs.eventtap.event.types.flagsChanged,
  }, function(event)
    local eventType = event:getType()
    local flags = event:getFlags()
    if eventType == hs.eventtap.event.types.flagsChanged then
      local mods = hs.eventtap.checkKeyboardModifiers()
      if state.active and not (flags.alt or mods.alt) then
        dbg("eventtap option_up -> stop")
        stop()
      end
      return false
    end

    if event:getKeyCode() ~= talkKey then
      return false
    end
    if eventType == hs.eventtap.event.types.keyDown then
      if event:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) == 1 then
        return flags.alt or state.active
      end
      if flags.alt then
        dbg("eventtap option_w_down -> start")
        start()
        return true
      end
      return false
    end
    if state.active or state.stopping then
      dbg("eventtap w_up -> stop")
      stop()
      return true
    end
    if flags.alt then
      return true
    end
    return false
  end)
  state.eventtap:start()
  state.hotkey = nil
  state.start = start
  state.stop = stop
  state.recognizeWav = function(wavBytes, callback)
    state.apiKey = resolveApiKey(state.apiKey)
    recognizeFlash({
      apiKey = state.apiKey,
      resourceID = state.resourceID,
      flashURL = state.flashURL,
    }, wavBytes, callback)
  end
  state.isActive = function()
    return state.active
  end
  state.debugLogPath = DEBUG_LOG
  return state
end

resetDebugLog()
dbg("module loaded debug=%s log=%s", tostring(DEBUG), DEBUG_LOG)
return M
