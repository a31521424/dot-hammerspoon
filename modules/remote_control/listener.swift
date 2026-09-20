import Foundation
import IOKit.hid

var targetVID = 0x2717
var targetPID = 0x32B8

let args = CommandLine.arguments
var i = 1
while i < args.count {
    if args[i] == "--vid" && i + 1 < args.count {
        let val = args[i + 1]
        targetVID = val.hasPrefix("0x") ? (Int(val.dropFirst(2), radix: 16) ?? targetVID) : (Int(val) ?? targetVID)
        i += 2
    } else if args[i] == "--pid" && i + 1 < args.count {
        let val = args[i + 1]
        targetPID = val.hasPrefix("0x") ? (Int(val.dropFirst(2), radix: 16) ?? targetPID) : (Int(val) ?? targetPID)
        i += 2
    } else {
        i += 1
    }
}

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let match: [String: Any] = [
    kIOHIDVendorIDKey: targetVID,
    kIOHIDProductIDKey: targetPID
]
IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)

let matchedCb: IOHIDDeviceCallback = { _, _, _, _ in
    fputs("{\"event\":\"device_matched\"}\n", stdout)
    fflush(stdout)
}
let removedCb: IOHIDDeviceCallback = { _, _, _, _ in
    fputs("{\"event\":\"device_removed\"}\n", stdout)
    fflush(stdout)
}
IOHIDManagerRegisterDeviceMatchingCallback(mgr, matchedCb, nil)
IOHIDManagerRegisterDeviceRemovalCallback(mgr, removedCb, nil)

let valueCb: IOHIDValueCallback = { _, _, _, value in
    let elem = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(elem)
    let usage = IOHIDElementGetUsage(elem)
    guard usage != 0xFFFFFFFF && usage != 0 && usage != 1 else { return }
    let intVal = IOHIDValueGetIntegerValue(value)
    let isDown = (intVal != 0)

    // Log raw input event
    fputs("{\"raw\":true,\"page\":\(usagePage),\"usage\":\(usage),\"val\":\(intVal),\"down\":\(isDown)}\n", stdout)
    fflush(stdout)

    var keyName: String? = nil
    if usagePage == 0x07 {
        switch usage {
        case 0x52: keyName = "up"
        case 0x51: keyName = "down"
        case 0x50: keyName = "left"
        case 0x4F: keyName = "right"
        case 0x28: keyName = "ok"
        case 0x3E: keyName = "voice"
        case 0xF1: keyName = "back"
        case 0x65: keyName = "menu"
        case 0x35: keyName = "tv"
        case 0x80: keyName = "volume_up"
        case 0x81: keyName = "volume_down"
        case 0x4A: keyName = "home"
        case 0x66: keyName = "power"
        default: break
        }
    } else if usagePage == 0x0C {
        switch usage {
        case 0x0224: keyName = "back"
        case 0xE9: keyName = "volume_up"
        case 0xEA: keyName = "volume_down"
        case 0x30: keyName = "power"
        case 0x223: keyName = "home"
        default: break
        }
    }

    if let key = keyName {
        fputs("{\"key\":\"\(key)\",\"down\":\(isDown)}\n", stdout)
        fflush(stdout)
    }
}

IOHIDManagerRegisterInputValueCallback(mgr, valueCb, nil)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
let ret = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
if ret != kIOReturnSuccess {
    fputs("{\"error\":\"failed_to_open_iohidmanager\",\"code\":\(ret)}\n", stdout)
    fflush(stdout)
    exit(1)
}

fputs("{\"event\":\"started\",\"vid\":\(targetVID),\"pid\":\(targetPID)}\n", stdout)
fflush(stdout)

CFRunLoopRun()
