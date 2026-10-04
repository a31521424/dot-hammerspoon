"""macOS integration test: stop WindowSwitcher before running this script.

Exercises the real WindowServer state without sending any keyboard input.
"""
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "modules/window_switcher/native_guard"
assert not (BINARY.parent / ".native-hotkeys.json").exists(), "Stop WindowSwitcher first"


def status():
    return json.loads(subprocess.check_output([str(BINARY), "--status"]))["enabled"]


def ready(process):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        assert selector.select(5), "guardian startup timeout"
        event = json.loads(process.stdout.readline())
        assert event["event"] == "ready", event
        return event


baseline = status()
children = []
with tempfile.TemporaryDirectory(prefix="window-switcher-guard-") as directory:
    journal = str(Path(directory) / "lease.json")

    def lease(parent=os.getpid()):
        process = subprocess.Popen([str(BINARY), "--lease", str(parent), journal],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        children.append(process)
        event = ready(process)
        assert event["original"] == baseline
        assert status() == [False, False]
        return process

    def restored(process):
        process.wait(timeout=5)
        assert process.returncode == 0 and status() == baseline
        assert not Path(journal).exists()

    try:
        process = lease()
        process.send_signal(signal.SIGTERM)
        restored(process)

        process = lease()
        process.stdin.close()
        restored(process)

        parent = subprocess.Popen(["/bin/sleep", "30"])
        children.append(parent)
        process = lease(parent.pid)
        parent.terminate()
        parent.wait(timeout=5)
        restored(process)

        process = lease()
        process.kill()
        process.wait(timeout=5)
        # A new guardian recovers the stale baseline before taking its own lease.
        process = lease()
        process.send_signal(signal.SIGTERM)
        restored(process)

        process = lease()
        owner = process.pid
        process.kill()
        process.wait(timeout=5)
        subprocess.run([str(BINARY), "--restore", str(owner + 1), journal], check=True,
                       stdout=subprocess.DEVNULL)
        assert Path(journal).exists() and status() == [False, False]
        subprocess.run([str(BINARY), "--restore", str(owner), journal], check=True,
                       stdout=subprocess.DEVNULL)
        assert status() == baseline and not Path(journal).exists()
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=5)
        if Path(journal).exists():
            owner = json.loads(Path(journal).read_text())["ownerPID"]
            subprocess.run([str(BINARY), "--restore", str(owner), journal], check=True)

print("PASS: guardian SIGTERM, EOF, parent exit, stale lease and owner-specific recovery")
