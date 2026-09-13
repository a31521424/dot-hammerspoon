-- Hold-to-talk voice input for Hammerspoon.
--
-- Hold Option + W to listen. Live text comes from Doubao streaming
-- ASR (SAUC) when that product is open; file Flash is the fallback.
-- A preview card shows the full transcript. Releasing the key stops
-- recording; after the stream (or leftover Flash) finishes, the
-- preview closes and the complete text is pasted at the caret.
-- System output is muted while listening so speaker audio is not
-- captured again by the microphone.
-- Customize recall words in ~/.hammerspoon/voice_hotwords.lua
-- (copy from voice_hotwords.lua.example). That file is local and
-- is not part of the project defaults.
local M = {}

local log = hs.logger.new("voice-input", "debug")
local API_KEY_ENV = "HAMMERSPOON_VOICE_DOUBAO_API_KEY"
local DEBUG = true
local DEBUG_LOG = (hs.configdir or os.getenv("HOME") .. "/.hammerspoon")
  .. "/voice_input_debug.log"

local function utf8Chars(text)
  local chars = {}
  if text == nil or text == "" then
    return chars
  end
  if utf8 ~= nil and utf8.codes ~= nil then
    for _, code in utf8.codes(text) do
      chars[#chars + 1] = utf8.char(code)
    end
    return chars
  end
  for index = 1, #text do
    chars[index] = text:sub(index, index)
  end
  return chars
end

local function joinTranscript(left, right)
  if left == nil or left == "" then
    return right or ""
  end
  if right == nil or right == "" then
    return left
  end
  local leftChars = utf8Chars(left)
  local rightChars = utf8Chars(right)
  local max = math.min(#leftChars, #rightChars, 12)
  for count = max, 1, -1 do
    local matched = true
    for index = 1, count do
      if leftChars[#leftChars - count + index] ~= rightChars[index] then
        matched = false
        break
      end
    end
    if matched then
      return left .. table.concat(rightChars, "", count + 1)
    end
  end
  return left .. right
end

local function addHotword(words, seen, word)
  if type(word) == "table" then
    word = word.word
  end
  if type(word) ~= "string" then
    return
  end
  word = word:gsub("^%s+", ""):gsub("%s+$", "")
  if word == "" or seen[word] then
    return
  end
  seen[word] = true
  words[#words + 1] = word
end

local function mergeHotwords(...)
  local words = {}
  local seen = {}
  for index = 1, select("#", ...) do
    local list = select(index, ...)
    if type(list) == "table" then
      for _, word in ipairs(list) do
        addHotword(words, seen, word)
      end
    end
  end
  return words
end

local function mergeReplacements(...)
  local merged = {}
  for index = 1, select("#", ...) do
    local list = select(index, ...)
    if type(list) == "table" then
      for from, to in pairs(list) do
        if type(from) == "string" and type(to) == "string" and from ~= "" then
          merged[from] = to
        end
      end
    end
  end
  return merged
end

local function configDir()
  return hs.configdir or ((os.getenv("HOME") or "") .. "/.hammerspoon")
end

local function defaultLexiconPath()
  return configDir() .. "/voice_hotwords.lua"
end

local function copyFile(src, dst)
  local input = io.open(src, "r")
  if input == nil then
    return false
  end
  local output = io.open(dst, "w")
  if output == nil then
    input:close()
    return false
  end
  output:write(input:read("*a") or "")
  input:close()
  output:close()
  return true
end

local function ensureLexiconFile(path)
  if path == nil or path == "" then
    return nil
  end
  if hs.fs.attributes(path, "mode") == "file" then
    return path
  end
  local example = configDir() .. "/voice_hotwords.lua.example"
  if hs.fs.attributes(example, "mode") == "file" and copyFile(example, path) then
    return path
  end
  local handle = io.open(path, "w")
  if handle == nil then
    return path
  end
  handle:write("return {\n  hotwords = {},\n  replacements = {},\n}\n")
  handle:close()
  return path
end

local function loadLexicon(path)
  local empty = { hotwords = {}, replacements = {} }
  if path == nil or hs.fs.attributes(path, "mode") ~= "file" then
    return empty
  end
  local chunk, err = loadfile(path)
  if chunk == nil then
    log.w("lexicon load_error path=" .. tostring(path) .. " err=" .. tostring(err))
    return empty
  end
  local ok, data = pcall(chunk)
  if not ok or type(data) ~= "table" then
    log.w("lexicon exec_error path=" .. tostring(path) .. " err=" .. tostring(data))
    return empty
  end
  return data
end

local function countPairs(map)
  local count = 0
  if type(map) ~= "table" then
    return 0
  end
  for _ in pairs(map) do
    count = count + 1
  end
  return count
end

local function replacePlain(text, from, to)
  local out = {}
  local pos = 1
  while true do
    local startAt, endAt = text:find(from, pos, true)
    if startAt == nil then
      out[#out + 1] = text:sub(pos)
      break
    end
    out[#out + 1] = text:sub(pos, startAt - 1)
    out[#out + 1] = to
    pos = endAt + 1
  end
  return table.concat(out)
end

local function applyReplacements(text, replacements)
  if type(text) ~= "string" or text == "" or type(replacements) ~= "table" then
    return text
  end
  local keys = {}
  for from, to in pairs(replacements) do
    if type(from) == "string" and from ~= "" and type(to) == "string" then
      keys[#keys + 1] = from
    end
  end
  table.sort(keys, function(a, b)
    return #a > #b
  end)
  for _, from in ipairs(keys) do
    text = replacePlain(text, from, replacements[from])
  end
  return text
end

local function corpusContext(hotwords)
  if type(hotwords) ~= "table" or #hotwords == 0 then
    return nil
  end
  local items = {}
  for _, word in ipairs(hotwords) do
    items[#items + 1] = { word = word }
  end
  return hs.json.encode({ hotwords = items })
end

local function collapseRunawayRepeat(text)
  if type(text) ~= "string" or #text < 36 then
    return text
  end
  local head = text:sub(1, 18)
  local starts = {}
  local pos = 1
  while true do
    local found = text:find(head, pos, true)
    if found == nil then
      break
    end
    starts[#starts + 1] = found
    pos = found + 1
  end
  if #starts < 3 then
    return text
  end
  return text:sub(starts[#starts])
end

local function previewText(text)
  if text == nil or text == "" then
    return ""
  end
  if #text > 72 then
    return text:sub(1, 72) .. "…"
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
local MIN_PCM_BYTES = BYTES_PER_SECOND * 0.28
local NEW_AUDIO_BYTES = BYTES_PER_SECOND * 0.15
local SEGMENT_SECONDS = 0.1
local LIVE_INTERVAL = 0.35
local FIRST_TICK_SECONDS = 0.28
local FORCE_WINDOW_SECONDS = 3.0
local SILENCE_WINDOW_SECONDS = 1.0
local SILENCE_TAIL_SECONDS = 0.25
local OVERLAP_SECONDS = 0.3
local SILENCE_LEVEL = 0.07
local FLIGHT_TIMEOUT = 5
local FINALIZE_DELAY = 0.12
local REUSE_TAIL_SECONDS = 0.28
local QUERY_INTERVAL = 0.8
local QUERY_TIMEOUT = 45
local MAX_RECORD_SECONDS = 120

local DEFAULT_FLASH_URL = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"
local DEFAULT_SUBMIT_URL = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit"
local DEFAULT_QUERY_URL = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/query"
local DEFAULT_RESOURCE_ID = "volc.seedasr.auc"
local DEFAULT_STREAM_URL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
local DEFAULT_STREAM_RESOURCE_ID = "volc.seedasr.sauc.duration"
local STREAM_TIMEOUT = 10
local MUTE_HOLD_SECONDS = 0.18

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

local function requestBody(wavBytes, hotwords)
  local request = {
    model_name = "bigmodel",
    enable_itn = true,
    enable_punc = true,
    enable_ddc = false,
    enable_speaker_info = false,
    enable_channel_split = false,
    show_utterances = false,
    vad_segment = false,
    sensitive_words_filter = "",
  }
  local context = corpusContext(hotwords)
  if context ~= nil then
    request.corpus = { context = context }
  end
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
    request = request,
  })
end

local function recognizeFlash(options, wavBytes, callback)
  local apiKey = options.apiKey
  local resourceID = options.resourceID or DEFAULT_RESOURCE_ID
  local flashURL = options.flashURL or DEFAULT_FLASH_URL
  local requestID = hs.host.uuid()
  local started = hs.timer.secondsSinceEpoch()

  hs.http.asyncPost(flashURL, requestBody(wavBytes, options.hotwords), {
    ["Content-Type"] = "application/json",
    ["X-Api-Key"] = apiKey,
    ["X-Api-Resource-Id"] = resourceID,
    ["X-Api-Request-Id"] = requestID,
    ["X-Api-Sequence"] = "-1",
  }, function(status, body, headers)
    local duration = hs.timer.secondsSinceEpoch() - started
    if status < 0 then
      dbg("flash transport_error dur=%.3f bytes=%d status=%s body=%s",
        duration, #wavBytes, tostring(status), tostring(body))
      callback(body or "recognize failed", nil)
      return
    end
    local code = headerValue(headers, "X-Api-Status-Code")
    local message = headerValue(headers, "X-Api-Message")
    if code == "20000003" then
      dbg("flash silence dur=%.3f bytes=%d http=%s code=%s",
        duration, #wavBytes, tostring(status), tostring(code))
      callback(nil, "")
      return
    end
    if status ~= 200 or code ~= "20000000" then
      dbg("flash error dur=%.3f bytes=%d http=%s code=%s msg=%s",
        duration, #wavBytes, tostring(status), tostring(code), tostring(message))
      callback(describeStatus(code or status, message or body), nil)
      return
    end
    local text = findText(decodeJson(body)) or ""
    dbg("flash ok dur=%.3f bytes=%d http=%s text_len=%d preview=%s",
      duration, #wavBytes, tostring(status), #text, previewText(text))
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

  hs.http.asyncPost(submitURL, requestBody(wavBytes, options.hotwords), {
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
  local lexiconPath = options.hotwordsPath or defaultLexiconPath()
  ensureLexiconFile(lexiconPath)
  local lexicon = loadLexicon(lexiconPath)
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
    streamURL = options.streamURL or DEFAULT_STREAM_URL,
    streamResourceID = options.streamResourceID or DEFAULT_STREAM_RESOURCE_ID,
    lexiconPath = lexiconPath,
    hotwords = mergeHotwords(lexicon.hotwords, options.hotwords),
    replacements = mergeReplacements(lexicon.replacements, options.replacements),
    streamPython = executable({
      (hs.configdir or (os.getenv("HOME") .. "/.hammerspoon")) .. "/.venv/bin/python",
    }),
    streamScript = (hs.configdir or (os.getenv("HOME") .. "/.hammerspoon")) .. "/voice_stream.py",
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
    streamTask = nil,
    streamBuf = "",
    usingStream = false,
    streamReady = false,
    streamDone = false,
    polishing = false,
    finished = false,
    outputGuard = nil,
    outputToken = 0,
    daemonTask = nil,
    daemonSocketPath = "/tmp/hammerspoon_voice_stream.sock",
    streamSocket = nil,
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

  local function killStream()
    if state.streamSocket ~= nil then
      pcall(function() state.streamSocket:disconnect() end)
      state.streamSocket = nil
    end
    if state.streamTask ~= nil and state.streamTask:isRunning() then
      state.streamTask:terminate()
    end
    state.streamTask = nil
    state.streamBuf = ""
  end

  local function writeStopFile()
    if state.segmentDir == nil then
      return
    end
    local file = io.open(state.segmentDir .. "/STOP", "w")
    if file ~= nil then
      file:write("1")
      file:close()
    end
  end

  -- The ASR API cannot separate speaker playback from the mic. Mute the
  -- default output only after a short hold so a tap cannot race restore.
  local function mutePlayback()
    state.outputToken = (state.outputToken or 0) + 1
    local token = state.outputToken
    hs.timer.doAfter(MUTE_HOLD_SECONDS, function()
      if token ~= state.outputToken or not state.active or state.stopping or state.failed then
        dbg("output mute skipped token=%d active=%s stopping=%s",
          token, tostring(state.active), tostring(state.stopping))
        return
      end
      if state.outputGuard ~= nil then
        return
      end
      local output = hs.audiodevice.defaultOutputDevice()
      if output == nil then
        dbg("output mute skipped no_device")
        return
      end
      local muted = false
      local volume = nil
      pcall(function()
        muted = output:muted() == true
      end)
      pcall(function()
        volume = output:volume()
      end)
      state.outputGuard = {
        uid = output:uid(),
        muted = muted,
        volume = volume,
      }
      local ok = pcall(function()
        output:setMuted(true)
      end)
      dbg("output mute ok=%s uid=%s was_muted=%s vol=%s",
        tostring(ok), tostring(state.outputGuard.uid), tostring(muted), tostring(volume))
    end)
  end

  local function restorePlayback()
    state.outputToken = (state.outputToken or 0) + 1
    local guard = state.outputGuard
    if guard == nil then
      return
    end
    state.outputGuard = nil
    local output = nil
    if guard.uid ~= nil then
      output = hs.audiodevice.findDeviceByUID(guard.uid)
    end
    if output == nil then
      output = hs.audiodevice.defaultOutputDevice()
    end
    if output == nil then
      dbg("output restore skipped no_device")
      return
    end
    if guard.muted then
      pcall(function()
        output:setMuted(true)
      end)
    else
      pcall(function()
        output:setMuted(false)
      end)
    end
    if guard.volume ~= nil then
      pcall(function()
        output:setVolume(guard.volume)
      end)
    end
    dbg("output restore uid=%s muted=%s vol=%s",
      tostring(guard.uid), tostring(guard.muted), tostring(guard.volume))
  end

  local function fail(message)
    if state.failed then
      return
    end
    local showPreview = state.active or state.stopping or (state.ui ~= nil and state.ui.visible)
    state.failed = true
    state.finished = true
    state.active = false
    state.stopping = false
    state.inFlight = false
    state.pendingFinal = false
    log.e(message)
    stopTimers()
    restorePlayback()
    killStream()
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
    return joinTranscript(state.sessionText, state.utteranceCommitted)
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
    local corrected = applyReplacements(text, state.replacements)
    if corrected ~= text then
      dbg("replace preview_from=%s preview_to=%s", previewText(text), previewText(corrected))
      text = corrected
    end
    text = collapseRunawayRepeat(text)
    if text == state.utteranceCommitted then
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
    state.sessionText = joinTranscript(state.sessionText, state.utteranceCommitted)
    state.utteranceCommitted = ""
    local recognized = state.windowStart + state.submittedBytes
    if recognized < state.windowStart then
      recognized = state.windowStart
    end
    if recognized > #state.pcmBuffer then
      recognized = #state.pcmBuffer
    end
    local keep = math.floor(OVERLAP_SECONDS * BYTES_PER_SECOND)
    local nextStart = recognized - keep
    if nextStart < beforeStart then
      nextStart = beforeStart
    end
    if nextStart < 0 then
      nextStart = 0
    end
    state.windowStart = nextStart
    state.submittedBytes = 0
    state.pendingRoll = false
    dbg("roll start %d->%d submitted=%d pcm=%d session_len=%d keep=%d",
      beforeStart, state.windowStart, beforeSubmitted, #state.pcmBuffer, #state.sessionText, keep)
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
    if state.finished then
      return
    end
    local gen = state.generation
    local text = sessionTranscript()
    state.finished = true
    state.active = false
    state.stopping = false
    state.inFlight = false
    state.pendingFinal = false
    state.finalStarted = false
    stopTimers()
    restorePlayback()
    cleanupCapture()
    if state.ui ~= nil then
      state.ui:hide()
    end
    killStream()
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

  local function polishWithFlash(gen)
    if state.finished or state.failed or state.generation ~= gen then
      return
    end
    if state.polishing then
      return
    end
    state.polishing = true
    ingestSegments(true)
    local pcm = state.pcmBuffer or ""
    dbg("polish pcm=%d stream_len=%d", #pcm, #sessionTranscript())
    if #pcm < MIN_PCM_BYTES then
      finishSession()
      return
    end
    if state.ui ~= nil then
      state.ui:setStatus("正在校对")
    end
    recognizeFlash({
      apiKey = state.apiKey,
      resourceID = state.resourceID,
      flashURL = state.flashURL,
      hotwords = state.hotwords,
    }, pcmToWav(pcm), function(err, text)
      if state.generation ~= gen or state.finished then
        return
      end
      if text ~= nil and text ~= "" then
        dbg("polish ok text_len=%d preview=%s", #text, previewText(text))
        state.sessionText = ""
        applyTranscript(text)
      else
        dbg("polish keep_stream err=%s", tostring(err))
      end
      finishSession()
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
    dbg("recognize send pcm=%d sec=%.2f final=%s window_start=%d",
      #pcm, #pcm / BYTES_PER_SECOND, tostring(final), state.windowStart)
    recognizeFlash({
      apiKey = state.apiKey,
      resourceID = state.resourceID,
      flashURL = state.flashURL,
      hotwords = state.hotwords,
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
        local leftover = #latest - state.submittedBytes
        if leftover < (REUSE_TAIL_SECONDS * BYTES_PER_SECOND) and sessionTranscript() ~= "" then
          dbg("finalize reuse_preview leftover=%d", leftover)
          finishSession()
        elseif #latest > MIN_PCM_BYTES and leftover > 0 then
          recognizePcm(latest, true, gen)
        else
          finishSession()
        end
        return
      end
      if final then
        finishSession()
        return
      end
      if state.stopping then
        return
      end
      ingestSegments(false)
      local nextPcm = windowPcm()
      if shouldRoll(nextPcm) and state.utteranceCommitted ~= "" then
        rollWindow()
        nextPcm = windowPcm()
      end
      if #nextPcm >= MIN_PCM_BYTES and (#nextPcm - state.submittedBytes) >= NEW_AUDIO_BYTES then
        dbg("recognize follow_up pcm=%d new=%d", #nextPcm, #nextPcm - state.submittedBytes)
        recognizePcm(nextPcm, false, gen)
      end
    end)
  end

  local function liveTick()
    if state.usingStream then
      return
    end
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

  local function startFlashLive()
    if state.liveTimer ~= nil or not state.active or state.failed then
      return
    end
    dbg("flash fallback live")
    state.usingStream = false
    state.liveTimer = hs.timer.doEvery(LIVE_INTERVAL, liveTick)
    hs.timer.doAfter(FIRST_TICK_SECONDS, liveTick)
  end

  local function handleStreamLine(line)
    if line == nil or line == "" or state.finished then
      return
    end
    local ok, msg = pcall(hs.json.decode, line)
    if not ok or type(msg) ~= "table" then
      dbg("stream bad_line %s", previewText(line))
      return
    end
    local event = msg.event
    if event == "ready" then
      state.streamReady = true
      dbg("stream ready")
      return
    end
    if event == "partial" or event == "final" then
      if type(msg.text) == "string" and msg.text ~= "" then
        state.sessionText = ""
        applyTranscript(msg.text)
      end
      return
    end
    if event == "done" then
      state.streamDone = true
      dbg("stream done preview_len=%d", #sessionTranscript())
      if state.streamSocket ~= nil then
        pcall(function() state.streamSocket:disconnect() end)
        state.streamSocket = nil
      end
      return
    end
    if event == "error" then
      dbg("stream error %s", tostring(msg.message))
      if state.streamSocket ~= nil then
        pcall(function() state.streamSocket:disconnect() end)
        state.streamSocket = nil
      end
      if sessionTranscript() == "" and state.active and not state.stopping then
        killStream()
        startFlashLive()
        return
      end
      if sessionTranscript() == "" then
        fail(msg.message or "Streaming ASR failed")
      end
    end
  end

  local function ensureDaemon()
    if state.streamPython == nil or hs.fs.attributes(state.streamScript, "mode") ~= "file" then
      return
    end
    if state.daemonTask ~= nil and state.daemonTask:isRunning() then
      return
    end
    local args = {
      state.streamScript,
      "--daemon",
      "--socket", state.daemonSocketPath,
    }
    state.daemonTask = hs.task.new(state.streamPython, function(code, stdout, stderr)
      dbg("daemon exit code=%s", tostring(code))
      state.daemonTask = nil
    end, function(_, stdout, stderr)
      if stderr and stderr ~= "" then
        dbg("daemon stderr %s", previewText(stderr))
      end
      return true
    end, args)
    if not state.daemonTask:start() then
      dbg("daemon start_failed")
      state.daemonTask = nil
    else
      dbg("daemon started pid=%s", tostring(state.daemonTask:pid()))
    end
  end

  local function startStream(gen)
    if state.streamPython == nil or hs.fs.attributes(state.streamScript, "mode") ~= "file" then
      dbg("stream unavailable python=%s", tostring(state.streamPython))
      startFlashLive()
      return
    end
    state.usingStream = true
    state.streamReady = false
    state.streamDone = false
    state.streamBuf = ""

    local function startViaTask()
      local keyFile = state.segmentDir .. "/.apikey"
      local keyHandle = io.open(keyFile, "w")
      if keyHandle ~= nil then
        keyHandle:write(state.apiKey)
        keyHandle:close()
      end
      local hotFile = state.segmentDir .. "/.hotwords.json"
      local hotHandle = io.open(hotFile, "w")
      if hotHandle ~= nil then
        local items = {}
        for _, word in ipairs(state.hotwords) do
          items[#items + 1] = { word = word }
        end
        hotHandle:write(hs.json.encode({ hotwords = items }))
        hotHandle:close()
      end
      local args = {
        state.streamScript,
        "--dir", state.segmentDir,
        "--url", state.streamURL,
        "--resource", state.streamResourceID,
        "--key-file", keyFile,
        "--hotwords-file", hotFile,
      }
      state.streamTask = hs.task.new(state.streamPython, function(code, stdout, stderr)
        if state.generation ~= gen then
          return
        end
        if stdout ~= nil and stdout ~= "" then
          state.streamBuf = (state.streamBuf or "") .. stdout
        end
        if state.streamBuf ~= nil and state.streamBuf ~= "" then
          for line in (state.streamBuf .. "\n"):gmatch("(.-)\n") do
            handleStreamLine(line)
          end
          state.streamBuf = ""
        end
        if stderr ~= nil and stderr ~= "" then
          dbg("stream exit_err %s", previewText(stderr))
        end
        dbg("stream exit code=%s ready=%s done=%s", tostring(code), tostring(state.streamReady), tostring(state.streamDone))
        state.streamTask = nil
        if state.failed or state.finished then
          return
        end
        if state.polishing then
          dbg("stream exit, flash polish in progress")
          return
        end
        if state.stopping or state.streamDone then
          polishWithFlash(gen)
          return
        end
        if sessionTranscript() == "" then
          startFlashLive()
        end
      end, function(_, stdout, stderr)
        if stderr ~= nil and stderr ~= "" then
          for errLine in stderr:gmatch("[^\n]+") do
            dbg("stream stderr %s", previewText(errLine))
          end
        end
        if stdout ~= nil and stdout ~= "" then
          state.streamBuf = state.streamBuf .. stdout
          while true do
            local pos = state.streamBuf:find("\n", 1, true)
            if pos == nil then
              break
            end
            local line = state.streamBuf:sub(1, pos - 1)
            state.streamBuf = state.streamBuf:sub(pos + 1)
            handleStreamLine(line)
          end
        end
        return true
      end, args)
      if not state.streamTask:start() then
        dbg("stream start_failed")
        state.streamTask = nil
        startFlashLive()
        return
      end
      dbg("stream start (task) gen=%d resource=%s", gen, state.streamResourceID)
    end

    ensureDaemon()
    local socketMode = hs.fs.attributes(state.daemonSocketPath, "mode")
    if socketMode == "socket" then
      local sock = hs.socket.new()
      sock:setTimeout(10)
      sock:setCallback(function(data, tag)
        if state.generation ~= gen or state.finished then
          return
        end
        if data ~= nil and data ~= "" then
          for line in data:gmatch("[^\r\n]+") do
            handleStreamLine(line)
          end
          if not state.streamDone and not state.finished then
            sock:read("\n")
          end
        end
      end)
      local connected = sock:connect(state.daemonSocketPath, function()
        if state.generation ~= gen or state.finished then
          sock:disconnect()
          return
        end
        state.streamSocket = sock
        local hotItems = {}
        for _, word in ipairs(state.hotwords) do
          hotItems[#hotItems + 1] = { word = word }
        end
        local req = {
          action = "start",
          dir = state.segmentDir,
          url = state.streamURL,
          resource = state.streamResourceID,
          api_key = state.apiKey,
          hotwords = hotItems,
        }
        sock:write(hs.json.encode(req) .. "\n")
        sock:read("\n")
        dbg("stream start (daemon) gen=%d resource=%s", gen, state.streamResourceID)
      end)
      if not connected then
        dbg("stream daemon connect returned nil, fallback to task")
        startViaTask()
      end
    else
      startViaTask()
    end

    hs.timer.doAfter(2.2, function()
      if state.generation == gen and state.active and state.usingStream and not state.streamReady then
        dbg("stream ready_timeout fallback_flash")
        killStream()
        startFlashLive()
      end
    end)
  end

  local function finalize()
    if state.usingStream then
      dbg("finalize skip stream")
      return
    end
    if state.failed or state.finalStarted then
      dbg("finalize skip failed=%s started=%s", tostring(state.failed), tostring(state.finalStarted))
      return
    end
    state.finalStarted = true
    ingestSegments(true)
    local pcm = windowPcm()
    local leftover = #pcm - state.submittedBytes
    dbg("finalize pcm=%d leftover=%d inflight=%s", #pcm, leftover, tostring(state.inFlight))
    if state.inFlight then
      state.pendingFinal = true
      dbg("finalize wait_inflight leftover=%d", leftover)
      return
    end
    if sessionTranscript() ~= "" and leftover < (REUSE_TAIL_SECONDS * BYTES_PER_SECOND) then
      dbg("finalize reuse_preview leftover=%d", leftover)
      finishSession()
      return
    end
    recognizePcm(pcm, true, state.generation)
  end

  local function stop()
    if not state.active or state.stopping then
      return
    end
    local gen = state.generation
    dbg("stop gen=%d pcm=%d preview_len=%d", gen, #state.pcmBuffer, #sessionTranscript())
    state.active = false
    state.stopping = true
    restorePlayback()
    if state.liveTimer ~= nil then
      state.liveTimer:stop()
      state.liveTimer = nil
    end
    if state.ui ~= nil then
      state.ui:setFinishing(true)
      state.ui:setStatus("正在校对")
      refreshPreview()
    end
    writeStopFile()
    if state.streamSocket ~= nil and state.streamSocket:connected() then
      pcall(function()
        state.streamSocket:write(hs.json.encode({ action = "stop" }) .. "\n")
      end)
    end
    if state.audioTask ~= nil and state.audioTask:isRunning() then
      local pid = state.audioTask:pid()
      if pid ~= nil then
        hs.execute("/bin/kill -9 " .. tostring(pid))
      else
        state.audioTask:terminate()
      end
    end
    if state.usingStream then
      polishWithFlash(gen)
      hs.timer.doAfter(STREAM_TIMEOUT, function()
        if state.generation == gen and not state.finished then
          dbg("stream stop_timeout")
          killStream()
          finishSession()
        end
      end)
      return
    end
    hs.timer.doAfter(FINALIZE_DELAY, function()
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
    killStream()
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
    state.finished = false
    state.lastResult = ""
    state.sessionText = ""
    state.utteranceCommitted = ""
    state.pcmBuffer = ""
    state.ingested = {}
    state.windowStart = 0
    state.submittedBytes = 0
    state.pendingRoll = false
    state.flightStarted = 0
    state.usingStream = false
    state.streamReady = false
    state.streamDone = false
    state.polishing = false
    state.streamBuf = ""
    state.segmentDir = tempSegmentDir()
    state.audioError = ""
    state.level = 0
    state.ui:setFinishing(false)
    state.ui:setStatus("正在听")
    state.ui:setTranscript("")
    state.ui:setLevel(0)
    state.ui:show()
    mutePlayback()

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
    dbg("start gen=%d device=%s lexicon=%s hotwords=%d replacements=%d",
      state.generation, tostring(state.captureDevice), tostring(state.lexiconPath),
      #state.hotwords, countPairs(state.replacements))

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

    startStream(state.generation)
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
      hotwords = state.hotwords,
    }, wavBytes, callback)
  end
  state.isActive = function()
    return state.active
  end
  state.debugLogPath = DEBUG_LOG
  dbg("lexicon ready path=%s hotwords=%d replacements=%d",
    tostring(state.lexiconPath), #state.hotwords, countPairs(state.replacements))
  ensureDaemon()
  return state
end

resetDebugLog()
dbg("module loaded debug=%s log=%s", tostring(DEBUG), DEBUG_LOG)
return M
