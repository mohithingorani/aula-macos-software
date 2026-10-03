import Foundation
import IOKit.hid
import IOKit.hidsystem

// Read-only receiver probe: sends only the documented configuration-read request.
let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x3554, kIOHIDProductIDKey: 0xFA09, kIOHIDPrimaryUsagePageKey: 0xFF02] as CFDictionary)
print("TCC", IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue)
guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first else { fatalError("Receiver not found") }
for key in [kIOHIDPrimaryUsagePageKey,kIOHIDPrimaryUsageKey,kIOHIDMaxInputReportSizeKey,kIOHIDMaxOutputReportSizeKey,kIOHIDMaxFeatureReportSizeKey] {
    print(key, IOHIDDeviceGetProperty(device,key as CFString) as Any)
}
print("descriptor", IOHIDDeviceGetProperty(device,kIOHIDReportDescriptorKey as CFString) as Any)
let opened = IOHIDDeviceOpen(device, 0)
print("open", String(format: "%08x",opened))
guard opened == kIOReturnSuccess else { exit(2) }
let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
IOHIDDeviceRegisterInputReportCallback(device, buffer, 1024, { _, result, _, _, id, bytes, length in
    guard id == 0x13 else { return } // Do not print keystroke reports.
    print("RX", result, id, length, Array(UnsafeBufferPointer(start: bytes, count: length)).map { String(format:"%02x",$0) }.joined(separator:" "))
}, nil)
IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
var request = [UInt8](repeating:0,count:20)
request[0]=0x13; request[1]=0x44; request[2]=1; request[19]=0x58
print("write",request.withUnsafeBytes { IOHIDDeviceSetReport(device,kIOHIDReportTypeOutput,0x13,$0.bindMemory(to:UInt8.self).baseAddress!,20) })
RunLoop.current.run(until:Date().addingTimeInterval(3))
IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
IOHIDDeviceClose(device,0)
