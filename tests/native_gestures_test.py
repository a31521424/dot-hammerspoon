"""Compile and test the actual Swift gesture ledger without changing hotkeys."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "modules/window_switcher/native_guard.swift").read_text()
ledger = source.split("// BEGIN GESTURE LEDGER\n", 1)[1].split("// END GESTURE LEDGER", 1)[0]
checks = """
let gestures = CommandGestures()
_ = gestures.flags(commandDown: true, at: 100)
// Carbon A and B wait behind the modifier fence; do not publish provisional IDs.
let pendingPresses = [100.1, 100.3]
_ = gestures.flags(commandDown: false, at: 100.2)
_ = gestures.flags(commandDown: true, at: 100.25)
let first = gestures.press(at: pendingPresses[0])!
let second = gestures.press(at: pendingPresses[1])!
assert(first.id != second.id && first.ended == 100.2)
assert(second.started == 100.25 && second.ended == nil)
// All late steps before the release still belong to the same immutable interval.
assert(gestures.press(at: 100.15)!.id == first.id)
assert(gestures.press(at: 99) == nil)
_ = gestures.flags(commandDown: false, at: 100.24) // cannot create a negative interval
assert(gestures.gesture(second.id)!.ended == nil)
_ = gestures.flags(commandDown: false, at: 100.4)
assert(gestures.gesture(second.id)!.ended == 100.4)
// Another active key tap may delay Carbon until after both physical gestures.
assert(gestures.observeTab(id: 1, at: 100.1))
assert(gestures.observeTab(id: 1, at: 100.3))
assert(gestures.hotkey(id: 1, at: 101)!.id == first.id)
assert(gestures.hotkey(id: 1, at: 101.1)!.id == second.id)
// Secure Input without observable Tab falls back to the native timestamp.
assert(gestures.hotkey(id: 1, at: 100.15)!.id == first.id)
assert(gestures.hotkey(id: 1, at: 101) == nil)
// A late Shift modifier after a recovered release cannot split one gesture.
let recovered = CommandGestures()
_ = recovered.flags(commandDown: true, at: 300)
_ = recovered.flags(commandDown: false, at: 300.3)
_ = recovered.flags(commandDown: true, at: 300.1)
_ = recovered.flags(commandDown: false, at: 300.2)
assert(recovered.history.count == 1)
assert(recovered.press(at: 300.05)!.id == recovered.press(at: 300.15)!.id)
_ = recovered.flags(commandDown: true, at: 300.4)
assert(recovered.press(at: 300.45)!.id != recovered.press(at: 300.15)!.id)
let startup = CommandGestures()
_ = startup.flags(commandDown: true, at: 0)
assert(startup.press(at: 200)!.started == 0)
for index in 1...100 {
    _ = startup.flags(commandDown: false, at: Double(index * 10))
    _ = startup.flags(commandDown: true, at: Double(index * 10 + 1))
}
assert(startup.history.count == 64)
print("PASS: immutable gesture intervals, delayed Carbon lookup, late steps and bounded history")
"""
with tempfile.TemporaryDirectory(prefix="window-switcher-gestures-") as directory:
    script = Path(directory) / "main.swift"
    binary = Path(directory) / "test"
    script.write_text(ledger + checks)
    subprocess.run(["/usr/bin/swiftc", "-module-cache-path", str(Path(directory) / "cache"),
                    str(script), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
