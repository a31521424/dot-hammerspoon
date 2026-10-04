import Cocoa
import Carbon
import Darwin

// Gesture history uses original event times, not callback delivery order.
// BEGIN GESTURE LEDGER
struct CommandGesture {
    let id: Int
    var started: Double
    var ended: Double?
}
struct ObservedTab {
    let id: UInt32
    let time: Double
}
final class CommandGestures {
    private(set) var tabs: [ObservedTab] = []
    private(set) var history: [CommandGesture] = []
    private var nextID = 0
    func press(at time: Double) -> CommandGesture? {
        history.last { $0.started <= time && ($0.ended == nil || time <= $0.ended!) }
    }
    func observeTab(id: UInt32, at time: Double) -> Bool {
        guard tabs.count < 256 else { return false }
        tabs.append(ObservedTab(id: id, time: time))
        return true
    }
    func hotkey(id: UInt32, at time: Double) -> CommandGesture? {
        // Normal input may be delayed by another app's active key tap. Its raw
        // Tab timestamp remains authoritative; Carbon is still the trigger.
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            let tab = tabs.remove(at: index)
            return press(at: tab.time)
        }
        // Secure Input normally hides Tab from observers. Carbon then reaches
        // the native hotkey route without waiting on ordinary keyboard taps.
        return press(at: time)
    }
    func expireTabs(before time: Double) { tabs.removeAll { $0.time < time } }
    func flags(commandDown: Bool, at time: Double) -> CommandGesture? {
        if commandDown {
            if history.last?.ended == nil && !history.isEmpty { return nil }
            // A delayed modifier event cannot split an already closed interval.
            if let ended = history.last?.ended, time <= ended { return nil }
            nextID += 1
            history.append(CommandGesture(id: nextID, started: time, ended: nil))
            if history.count > 64 { history.removeFirst() }
            return nil
        }
        guard let index = history.lastIndex(where: { $0.ended == nil }),
              time >= history[index].started else { return nil }
        history[index].ended = time
        return history[index]
    }
    func gesture(_ id: Int) -> CommandGesture? { history.first { $0.id == id } }
}
// END GESTURE LEDGER

// AltTab uses these WindowServer symbolic hotkeys before registering Carbon
// shortcuts. Changes outlive the caller, so a separate process owns restoration.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

typealias QueryHotkey = @convention(c) (Int32) -> Bool
typealias SetHotkey = @convention(c) (Int32, Bool) -> Int32
let ids: [Int32] = [1, 2]
signal(SIGPIPE, SIG_IGN)
_ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK)
var outputFailed = false
func emit(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value) {
        let line = data + Data([10])
        let count = line.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        if count != line.count { outputFailed = true }
    }
}
func fail(_ message: String) -> Never {
    emit(["event": "error", "message": message])
    exit(1)
}
guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
      let querySymbol = dlsym(library, "CGSIsSymbolicHotKeyEnabled"),
      let setSymbol = dlsym(library, "CGSSetSymbolicHotKeyEnabled") else {
    fail("WindowServer symbolic-hotkey APIs are unavailable")
}
let query = unsafeBitCast(querySymbol, to: QueryHotkey.self)
let setEnabled = unsafeBitCast(setSymbol, to: SetHotkey.self)
let arguments = CommandLine.arguments
if arguments.count == 2 && arguments[1] == "--status" {
    emit(["event": "status", "enabled": ids.map { query($0) }, "clock": GetCurrentEventTime()])
    exit(0)
}
guard arguments.count == 4,
      arguments[1] == "--lease" || arguments[1] == "--restore",
      let pid = Int32(arguments[2]), pid > 1 else {
    fail("usage: native_guard --lease parentPID journal | --restore ownerPID journal | --status")
}
let journalURL = URL(fileURLWithPath: arguments[3])
let lockFD = open(arguments[3] + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
guard lockFD >= 0 else { fail("could not open native-hotkey lease lock") }
let deadline = Date().addingTimeInterval(3)
while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    guard Date() < deadline else { fail("another native-hotkey guardian owns the lease") }
    usleep(20_000)
}
struct Journal: Codable {
    let ownerPID: Int32
    let parentPID: Int32
    let enabled: [Bool]
}
func readJournal() -> Journal? {
    guard let data = try? Data(contentsOf: journalURL) else { return nil }
    return try? JSONDecoder().decode(Journal.self, from: data)
}
func restore(_ record: Journal) -> Bool {
    guard record.enabled.count == ids.count else { return false }
    var success = true
    for (id, enabled) in zip(ids, record.enabled) {
        if setEnabled(id, enabled) != 0 || query(id) != enabled { success = false }
    }
    if success, readJournal()?.ownerPID == record.ownerPID {
        try? FileManager.default.removeItem(at: journalURL)
    }
    return success
}
func processExists(_ process: Int32) -> Bool {
    return kill(process, 0) == 0 || errno == EPERM
}
if arguments[1] == "--restore" {
    guard let old = readJournal(), old.ownerPID == pid else {
        emit(["event": "restored", "changed": false])
        exit(0)
    }
    guard !processExists(old.ownerPID) else { fail("refusing to restore a live guardian's lease") }
    guard restore(old) else { fail("could not restore original native hotkeys") }
    emit(["event": "restored", "changed": true])
    exit(0)
}
guard processExists(pid) else { fail("Hammerspoon process is not running") }
// Recover a journal left by SIGKILL or a crash before claiming a new lease.
if let old = readJournal() {
    guard !processExists(old.ownerPID) else { fail("existing guardian is still running") }
    guard restore(old) else { fail("could not recover previous native-hotkey lease") }
}
let record = Journal(ownerPID: getpid(), parentPID: pid, enabled: ids.map { query($0) })
do {
    let data = try JSONEncoder().encode(record)
    try data.write(to: journalURL, options: .atomic)
    chmod(journalURL.path, S_IRUSR | S_IWUSR)
} catch { fail("could not persist original native-hotkey state") }

var signals: [DispatchSourceSignal] = []
var hotkeys: [UInt32: EventHotKeyRef] = [:]
var handler: EventHandlerRef?
var repeatDelay: Timer?
var repeatTimer: Timer?
var repeatingID: UInt32?
var sessionGesture: Int?
var repeatGesture: Int?
let gestures = CommandGestures()
var modifierTap: CFMachPort?
var modifierSource: CFRunLoopSource?
if CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) {
    _ = gestures.flags(commandDown: true, at: 0) // Starting while Command is already held.
}
func stopRepeating() {
    repeatDelay?.invalidate(); repeatDelay = nil
    repeatTimer?.invalidate(); repeatTimer = nil
    repeatingID = nil
    repeatGesture = nil
}
func publish(_ name: String, gesture: CommandGesture, repeated: Bool = false, time: Double? = nil) {
    emit(["event": name, "gesture": gesture.id, "started": gesture.started,
          "time": time ?? gesture.started, "repeated": repeated])
}
func confirm(_ gesture: CommandGesture) {
    publish("confirm", gesture: gesture, time: gesture.ended)
    if repeatGesture == gesture.id { stopRepeating() }
    if sessionGesture == gesture.id { setSession(nil) }
}
func observeModifiers(_ down: Bool, at time: Double) {
    if let ended = gestures.flags(commandDown: down, at: time) { confirm(ended) }
}
// Selector timers run on this main run loop; their callbacks never execute
// concurrently with Carbon, the modifier tap or the guardian's dispatch sources.
final class RepeatAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire(_ timer: Timer) { action() }
}
func scheduleRepeat(after delay: Double, repeats: Bool, action: @escaping () -> Void) -> Timer {
    Timer.scheduledTimer(timeInterval: delay, target: RepeatAction(action),
        selector: #selector(RepeatAction.fire(_:)), userInfo: nil, repeats: repeats)
}
func startRepeating(_ id: UInt32, gesture: CommandGesture) {
    stopRepeating()
    guard gesture.ended == nil else { return }
    repeatingID = id
    repeatGesture = gesture.id
    repeatDelay = scheduleRepeat(after: max(0.1, NSEvent.keyRepeatDelay), repeats: false) {
        guard repeatingID == id, repeatGesture == gesture.id,
              let current = gestures.gesture(gesture.id), current.ended == nil else { return }
        queueRepeat(id, gesture: current.id)
        repeatTimer = scheduleRepeat(after: max(0.02, NSEvent.keyRepeatInterval), repeats: true) {
            if repeatingID == id, repeatGesture == gesture.id,
               let current = gestures.gesture(gesture.id), current.ended == nil {
                queueRepeat(id, gesture: current.id)
            }
        }
    }
}
func register(_ id: UInt32, key: UInt32, modifiers: UInt32) -> Bool {
    var ref: EventHotKeyRef?
    let hotkey = EventHotKeyID(signature: 0x48535753, id: id) // HSWS
    let status = RegisterEventHotKey(key, modifiers, hotkey, GetEventDispatcherTarget(),
                                    UInt32(kEventHotKeyNoOptions), &ref)
    if status != noErr { return false }
    hotkeys[id] = ref
    return true
}
func setSession(_ gestureID: Int?) {
    if sessionGesture == gestureID { return }
    for id in hotkeys.keys.filter({ $0 > 2 }) {
        if let ref = hotkeys.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }
    sessionGesture = gestureID
    if let gestureID = gestureID {
        guard gestureID <= (Int(UInt32.max) - 5) / 3 else { finish(1) }
        // The ID itself carries the gesture, even if a release unregisters
        // Escape before its already queued Carbon callback reaches this loop.
        let base = UInt32(3 + gestureID * 3)
        for (offset, modifiers) in [(UInt32(0), UInt32(0)), (1, UInt32(cmdKey)), (2, UInt32(cmdKey | shiftKey))] {
            if !register(base + offset, key: UInt32(kVK_Escape), modifiers: modifiers) {
                emit(["event": "error", "message": "could not register session Escape hotkeys"])
                finish(1)
            }
        }
    }
}
func finish(_ code: Int32) -> Never {
    stopRepeating()
    if let tap = modifierTap { CGEvent.tapEnable(tap: tap, enable: false) }
    for ref in hotkeys.values { UnregisterEventHotKey(ref) }
    hotkeys.removeAll()
    let success = restore(record)
    emit(["event": "restored", "success": success])
    exit(success ? code : 1)
}
for number in [SIGTERM, SIGINT, SIGHUP] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { finish(0) }
    source.resume()
    signals.append(source)
}
// A tagged null event is a fence through the same session tap. Carbon actions
// wait for it, so earlier modifier notifications are processed before lookup.
// Null events do not change keys, flags, mouse position or text.
let markerMagic: Int64 = 0x4853000000000000
let markerMask: Int64 = ~Int64(0xFFFFFFFF)
struct PendingHotkey {
    let sequence: Int64
    let id: UInt32
    let pressed: Bool
    let time: Double
    let escapeGesture: Int?
    let repeated: Bool
    let originalTime: Double?
}
var pendingHotkeys: [PendingHotkey] = []
var pendingMarkers: [Int64: Double] = [:]
var nextMarker: Int64 = 0
var watchMarkers: [Int64: Int] = [:]
var lastTriggeredGesture: Int?
func postMarker(_ sequence: Int64) {
    guard let event = CGEvent(source: nil) else {
        emit(["event": "error", "message": "could not create modifier barrier"])
        finish(1)
    }
    pendingMarkers[sequence] = GetCurrentEventTime()
    event.setIntegerValueField(.eventSourceUserData, value: markerMagic | sequence)
    event.post(tap: .cgSessionEventTap)
}
func queueRepeat(_ id: UInt32, gesture: Int) {
    guard nextMarker < 0xFFFFFFFF, pendingHotkeys.count < 256 else {
        emit(["event": "error", "message": "native input queue overflow"])
        finish(1)
    }
    nextMarker += 1
    pendingHotkeys.append(PendingHotkey(sequence: nextMarker, id: id, pressed: true,
        time: GetCurrentEventTime(), escapeGesture: gesture, repeated: true, originalTime: nil))
    postMarker(nextMarker)
}
func handleHotkey(_ pending: PendingHotkey) {
    if pending.repeated {
        guard let id = pending.escapeGesture, repeatGesture == id, repeatingID == pending.id,
              let gesture = gestures.gesture(id), gesture.ended == nil else { return }
        publish(pending.id == 1 ? "next" : "previous", gesture: gesture, repeated: true, time: pending.time)
        return
    }
    if pending.pressed {
        if pending.id <= 2 {
            let paired = gestures.hotkey(id: pending.id, at: pending.time)
            let original = pending.originalTime.flatMap { gestures.press(at: $0) }
            guard let gesture = original ?? paired else {
                emit(["event": "error", "message": "missing Command gesture for native hotkey",
                      "hotkeyTime": pending.time,
                      "intervals": gestures.history.map { ["started": $0.started, "ended": $0.ended ?? -1] }])
                finish(1)
            }
            lastTriggeredGesture = gesture.id
            publish(pending.id == 1 ? "next" : "previous", gesture: gesture, time: pending.time)
            if gesture.ended != nil { confirm(gesture) }
            else { startRepeating(pending.id, gesture: gesture) }
        } else if let id = pending.escapeGesture, let gesture = gestures.gesture(id) {
            publish("cancel", gesture: gesture, time: pending.time)
            if repeatGesture == id { stopRepeating() }
            if sessionGesture == id { setSession(nil) }
        }
    } else if pending.id <= 2, let id = repeatGesture,
              let gesture = gestures.gesture(id), pending.time >= gesture.started {
        if repeatingID == pending.id { stopRepeating() }
    }
}
func acceptMarker(_ sequence: Int64) {
    guard pendingMarkers.removeValue(forKey: sequence) != nil else { return }
    if sequence == 0 {
        emit(["event": "ready", "ownerPID": record.ownerPID, "original": record.enabled])
    }
    let completed = pendingHotkeys.prefix { $0.sequence <= sequence }
    let count = completed.count
    // Copy before dispatch, because finish/session functions change other state.
    let actions = Array(completed)
    pendingHotkeys.removeFirst(count)
    for action in actions { handleHotkey(action) }
    if let watched = watchMarkers.removeValue(forKey: sequence),
       let current = gestures.history.last, current.id == watched, current.ended == nil,
       !CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) {
        observeModifiers(false, at: GetCurrentEventTime())
    }
}
modifierTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
    options: .listenOnly, eventsOfInterest: CGEventMask((1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.null.rawValue) | (1 << CGEventType.keyDown.rawValue)),
    callback: { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = modifierTap { CGEvent.tapEnable(tap: tap, enable: true) }
        } else if type == .null {
            let marker = event.getIntegerValueField(.eventSourceUserData)
            if marker & markerMask == markerMagic { acceptMarker(marker & 0xFFFFFFFF) }
        } else if type == .keyDown {
            // Read keycode/flags only; never decode or retain text. Ordinary
            // keys and secure password events are not used for triggering.
            let flags = event.flags
            if event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Tab),
               flags.contains(.maskCommand),
               flags.intersection([.maskAlternate, .maskControl, .maskSecondaryFn]).isEmpty,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                let time = event.timestamp == 0 ? GetCurrentEventTime() : Double(event.timestamp) / 1_000_000_000
                let id: UInt32 = flags.contains(.maskShift) ? 2 : 1
                if !gestures.observeTab(id: id, at: time) {
                    emit(["event": "error", "message": "native Tab observation queue overflow"])
                    finish(1)
                }
            }
        } else if type == .flagsChanged {
            let time = event.timestamp == 0 ? GetCurrentEventTime() : Double(event.timestamp) / 1_000_000_000
            observeModifiers(event.flags.contains(.maskCommand), at: time)
        }
        return Unmanaged.passUnretained(event)
    }, userInfo: nil)
guard let tap = modifierTap,
      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
    emit(["event": "error", "message": "could not observe Command modifiers"])
    finish(1)
}
modifierSource = source
CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
for id in ids {
    if setEnabled(id, false) != 0 || query(id) {
        _ = restore(record)
        fail("could not suspend native Command-Tab")
    }
}
var eventTypes = [
    EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
    EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
]
let handlerStatus = InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
    var hotkey = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hotkey)
    guard status == noErr, hotkey.signature == 0x48535753 else { return OSStatus(eventNotHandledErr) }
    guard nextMarker < 0xFFFFFFFF, pendingHotkeys.count < 256 else {
        emit(["event": "error", "message": "native input queue overflow"])
        finish(1)
    }
    nextMarker += 1
    var originalTime: Double?
    if let copied = CopyEventCGEvent(event) {
        let original = copied.takeRetainedValue()
        if original.type == .keyDown || original.type == .keyUp,
           original.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Tab), original.timestamp > 0 {
            originalTime = Double(original.timestamp) / 1_000_000_000
        }
    }
    pendingHotkeys.append(PendingHotkey(sequence: nextMarker, id: hotkey.id,
        pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed),
        time: GetEventTime(event), escapeGesture: hotkey.id > 2 ? Int((hotkey.id - 3) / 3) : nil, repeated: false, originalTime: originalTime))
    postMarker(nextMarker)
    return noErr
}, eventTypes.count, &eventTypes, nil, &handler)
guard handlerStatus == noErr,
      register(1, key: UInt32(kVK_Tab), modifiers: UInt32(cmdKey)),
      register(2, key: UInt32(kVK_Tab), modifiers: UInt32(cmdKey | shiftKey)) else {
    emit(["event": "error", "message": "could not register native Command-Tab hotkeys"])
    finish(1)
}
_ = fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK)
var inputBuffer = ""
let inputWatch = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
inputWatch.setEventHandler {
    var bytes = [UInt8](repeating: 0, count: 1024)
    let count = read(STDIN_FILENO, &bytes, bytes.count)
    if count == 0 { finish(0) }
    if count > 0 {
        inputBuffer += String(decoding: bytes.prefix(count), as: UTF8.self)
        while let end = inputBuffer.firstIndex(of: "\n") {
            let command = String(inputBuffer[..<end])
            inputBuffer.removeSubrange(...end)
            let parts = command.split(separator: " ")
            if parts.count == 2, let id = Int(parts[1]) {
                if parts[0] == "active", let gesture = gestures.gesture(id), gesture.ended == nil {
                    setSession(id)
                }
                if parts[0] == "inactive" {
                    if sessionGesture == id { setSession(nil) }
                    if repeatGesture == id { stopRepeating() }
                }
            }
            if command == "release" { finish(0) }
        }
    }
}
inputWatch.resume()
let parentWatch = DispatchSource.makeTimerSource(queue: .main)
parentWatch.schedule(deadline: .now(), repeating: .milliseconds(50))
parentWatch.setEventHandler {
    if !processExists(pid) || outputFailed { finish(0) }
    if pendingMarkers.values.contains(where: { GetCurrentEventTime() - $0 > 1 }) {
        emit(["event": "error", "message": "modifier barrier timed out"])
        finish(1)
    }
    if let tap = modifierTap, !CGEvent.tapIsEnabled(tap: tap) {
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    if pendingMarkers.isEmpty && pendingHotkeys.isEmpty {
        gestures.expireTabs(before: GetCurrentEventTime() - 1)
    }
    // A release watchdog uses the same fence as key input. Never close from
    // an unchecked timer snapshot while modifier notifications are queued.
    if pendingMarkers.isEmpty, let current = gestures.history.last,
       current.ended == nil, current.id == lastTriggeredGesture,
       !CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) {
        guard nextMarker < 0xFFFFFFFF else { finish(1) }
        nextMarker += 1
        watchMarkers[nextMarker] = current.id
        postMarker(nextMarker)
    }
}
parentWatch.resume()
postMarker(0) // Startup also proves the barrier works before reporting readiness.
app.run()
finish(0)
