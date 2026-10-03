import Foundation
@preconcurrency import IOKit.hid
@preconcurrency import IOKit.hidsystem

@MainActor
final class F75Device: ObservableObject {
    enum Link { case wired, wireless }

    @Published private(set) var connected = false
    @Published private(set) var connection = "No configurable F75 found"
    @Published private(set) var detail = "Use the USB cable or 2.4 GHz receiver. Bluetooth cannot carry configuration commands."
    @Published private(set) var needsPermission = false
    @Published private(set) var isWired = false

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var device: IOHIDDevice?
    private var link: Link?
    private var input: HIDInputMonitor?

    init() {
        let matches: [[String: Any]] = [
            [kIOHIDVendorIDKey: F75Protocol.wiredVendor, kIOHIDProductIDKey: F75Protocol.wiredProduct],
            [kIOHIDVendorIDKey: F75Protocol.wirelessVendor,
             kIOHIDProductIDKey: F75Protocol.wirelessProduct,
             kIOHIDPrimaryUsagePageKey: 0xFF02,
             kIOHIDPrimaryUsageKey: 0x02],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
    }

    deinit {
        input?.stop()
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func scan() {
        close()
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        let candidates = devices.compactMap { candidate -> (IOHIDDevice, Link, Int)? in
            let vendor = property(candidate, kIOHIDVendorIDKey)
            let product = property(candidate, kIOHIDProductIDKey)
            let feature = property(candidate, kIOHIDMaxFeatureReportSizeKey)
            let output = property(candidate, kIOHIDMaxOutputReportSizeKey)
            if vendor == F75Protocol.wiredVendor, product == F75Protocol.wiredProduct, feature >= 136 {
                return (candidate, .wired, feature)
            }
            if vendor == F75Protocol.wirelessVendor, product == F75Protocol.wirelessProduct, output >= 20 {
                return (candidate, .wireless, output)
            }
            return nil
        }.sorted { $0.2 > $1.2 }

        guard let found = candidates.first else { return }
        // The manager caches device objects (including callback registrations).
        // Own a fresh handle per connection so Refresh cannot revive old callbacks.
        guard let openedDevice = IOHIDDeviceCreate(kCFAllocatorDefault, IOHIDDeviceGetService(found.0)) else {
            detail = "F75 detected, but its configuration interface could not be created."
            return
        }
        let result = IOHIDDeviceOpen(openedDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            connection = "F75 detected · access blocked"
            needsPermission = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted
            detail = needsPermission
                ? "macOS has not granted this exact build access. Remove the old AULA F75 entry from Input Monitoring, add this app again, then reopen it."
                : "Input Monitoring is allowed, but macOS would not open the receiver (error \(result)). Unplug it, close other keyboard tools, and reconnect it."
            return
        }
        device = openedDevice
        link = found.1
        if found.1 == .wireless { input = HIDInputMonitor(device: openedDevice) }
        connected = true
        isWired = found.1 == .wired
        connection = found.1 == .wired ? "AULA F75 · USB" : "AULA F75 · 2.4 GHz"
        detail = "Ready. Changes are stored by the keyboard. Hold Fn + Esc for about 5 seconds to factory-reset it."
    }

    func requestPermission() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        detail = "After allowing AULA F75 in Input Monitoring, quit and reopen the app."
    }

    func apply(effect: Effect, brightness: Int, speed: Int, colorful: Bool, color: RGB) throws {
        guard let device, let link else { throw DeviceError.notConnected }
        stopPreview()
        switch link {
        case .wired:
            try setReport(device, type: kIOHIDReportTypeFeature, id: 0x06, bytes: F75Protocol.configRead())
            var response = [UInt8](repeating: 0, count: F75Protocol.reportLength)
            response[0] = 0x06
            var length = response.count
            let result = response.withUnsafeMutableBytes {
                IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0x06, $0.bindMemory(to: UInt8.self).baseAddress!, &length)
            }
            guard result == kIOReturnSuccess else { throw DeviceError.io("Read failed", result) }
            try setReport(device, type: kIOHIDReportTypeFeature, id: 0x06,
                          bytes: F75Protocol.configWrite(from: response, effect: effect, brightness: brightness, speed: speed, colorful: colorful))
            if effect != .off {
                try setReport(device, type: kIOHIDReportTypeFeature, id: 0x06, bytes: F75Protocol.colorProfile(color, effect: effect))
            }
        case .wireless:
            let original = try readWirelessConfig(device)
            let frames = F75Protocol.wirelessApply(effect: effect, brightness: brightness, speed: speed, colorful: colorful, color: color, config: original)
            for report in frames { try wirelessExchange(device, report: report) }
            let actual = try readWirelessConfig(device)
            guard actual[0][15] == effect.hardwareID else {
                throw DeviceError.verification("Effect requested \(effect.hardwareID), received \(actual[0][15]).")
            }
            // Check all effect parameter bytes, excluding firmware-normalized trailers.
            for index in 4...8 where actual[index][5..<19] != frames[index][5..<19] {
                throw DeviceError.verification("Effect parameters differ in configuration fragment \(index).")
            }
        }
        detail = link == .wireless
            ? (effect == .off ? "Lighting turned off and verified." : "Applied and verified \(effect.title).")
            : "Sent \(effect.title) over USB; device read-back is not yet verified."
    }

    func applyPerKey(_ colors: [Int: RGB]) throws {
        guard !colors.isEmpty else { throw DeviceError.emptyColors }
        guard let device, let link else { throw DeviceError.notConnected }
        switch link {
        case .wireless:
            let original = try readWirelessConfig(device)
            for report in F75Protocol.wirelessPerKey(colors, config: original) { try wirelessExchange(device, report: report) }
            guard try readWirelessConfig(device)[0][15] == 21 else { throw DeviceError.noReply }
        case .wired:
            stopPreview()
            var config = try readWiredConfig(device)
            config[18] = 22
            try writeWiredConfig(device, response: config)
            try setReport(device, type: kIOHIDReportTypeFeature, id: 0x06, bytes: F75Protocol.colorTable(colors))
            try enableDirectMode(device)
            previewFrame = F75Protocol.directFrame(colors)
            try sendPreview()
            startPreviewTimer()
        }
        detail = "Applied custom colors to \(colors.count) keys."
    }

    func applyKeymap(layer: Int, mappings: [Int: HIDOutput]) throws {
        guard let device, link == .wired else { throw DeviceError.wiredOnly }
        try setReport(device, type: kIOHIDReportTypeFeature, id: 0x06, bytes: F75Protocol.keymap(layer: layer, mappings: mappings))
        detail = "Applied \(layer == 0 ? "Default" : "Fn") key layer."
    }

    func setSleep(seconds: Int) throws {
        guard let device, let link else { throw DeviceError.notConnected }
        switch link {
        case .wired:
            var config = try readWiredConfig(device)
            config[8 + 80] = UInt8(clamping: seconds / 30)
            try writeWiredConfig(device, response: config)
            guard try readWiredConfig(device)[8 + 80] == UInt8(clamping: seconds / 30) else { throw DeviceError.noReply }
        case .wireless:
            var config = try readWirelessConfig(device)
            config[1][15] = UInt8(clamping: seconds / 30)
            try writeWirelessConfig(device, reports: config)
            guard try readWirelessConfig(device)[1][15] == UInt8(clamping: seconds / 30) else { throw DeviceError.noReply }
        }
        detail = "Sleep timer set to \(seconds / 60)m \(seconds % 60)s."
    }

    func setDebounce(milliseconds: Int) throws {
        guard let device, let link else { throw DeviceError.notConnected }
        switch link {
        case .wired:
            var config = try readWiredConfig(device)
            config[8 + 73] = UInt8(clamping: milliseconds - 1)
            try writeWiredConfig(device, response: config)
            guard try readWiredConfig(device)[8 + 73] == UInt8(clamping: milliseconds - 1) else { throw DeviceError.noReply }
        case .wireless:
            var config = try readWirelessConfig(device)
            config[0][8] = UInt8(clamping: milliseconds - 1)
            try writeWirelessConfig(device, reports: config)
            guard try readWirelessConfig(device)[0][8] == UInt8(clamping: milliseconds - 1) else { throw DeviceError.noReply }
        }
        detail = "Debounce set to \(milliseconds) ms."
    }

    private func close() {
        input?.stop()
        input = nil
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        musicConfig = nil
        wirelessMusicConfig = nil
        musicSession = nil
        previousPreview = []
        link = nil
        isWired = false
        stopPreview()
        connected = false
        needsPermission = false
        connection = "No configurable F75 found"
        detail = "Use the USB cable or 2.4 GHz receiver. Bluetooth cannot carry configuration commands."
    }

    private func setReport(_ device: IOHIDDevice, type: IOHIDReportType, id: CFIndex, bytes: [UInt8]) throws {
        guard bytes.first == UInt8(id) else { throw DeviceError.malformedReport }
        let result = bytes.withUnsafeBytes {
            IOHIDDeviceSetReport(device, type, id, $0.bindMemory(to: UInt8.self).baseAddress!, bytes.count)
        }
        guard result == kIOReturnSuccess else { throw DeviceError.io("Write failed", result) }
    }

    private var previewFrame: [UInt8] = []
    private var previewTimer: Timer?
    private var musicConfig: [UInt8]?
    private var wirelessMusicConfig: [[UInt8]]?
    private var musicSession: UUID?
    private var previousPreview: [UInt8] = []

    func beginMusicSync() throws {
        guard let device, let link else { throw DeviceError.notConnected }
        if musicSession != nil { try endMusicSync() }
        if link == .wireless {
            // Stream into the current mode; never substitute a wired config or a template.
            let original = try readWirelessConfig(device)
            guard F75Protocol.validWirelessConfig(original) else { throw F75Protocol.ProtocolError.invalidConfig }
            wirelessMusicConfig = original
            musicSession = UUID()
            return
        }
        let original = try readWiredConfig(device)
        guard original[0] == 0x06, original[1] == 0x84 else { throw F75Protocol.ProtocolError.invalidConfig }
        musicConfig = original
        musicSession = UUID()
        previousPreview = previewFrame
        stopPreview()
        var config = original
        config[18] = 22
        try writeWiredConfig(device, response: config)
        try enableDirectMode(device)
    }

    func sendMusicColor(_ color: RGB) async throws {
        guard let device, let link, let session = musicSession else { throw DeviceError.notConnected }
        try Task.checkCancellation()
        if link == .wired {
            let colors = Dictionary(uniqueKeysWithValues: F75Protocol.keys.flatMap { $0 }.map { ($0.index, color) })
            try setReport(device, type: kIOHIDReportTypeFeature, id: 0x06, bytes: F75Protocol.directFrame(colors))
        } else {
            for frame in try F75Protocol.wirelessMusicFrames(color: color) {
                try Task.checkCancellation()
                guard musicSession == session else { throw CancellationError() }
                // Live 0x88 frames have no documented ACK. Pace every output (including
                // message boundaries) below 64 reports/sec without blocking the UI.
                try setReport(device, type: kIOHIDReportTypeOutput, id: 0x13, bytes: frame)
                try await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func endMusicSync() throws {
        musicSession = nil // Invalidate any frame suspended between wireless fragments.
        if let original = wirelessMusicConfig {
            defer { wirelessMusicConfig = nil }
            guard let device, link == .wireless else { throw DeviceError.notConnected }
            // Live frames never save a profile. Reapply its existing bytes to end
            // the override, without an unnecessary flash-save command.
            try writeWirelessConfig(device, reports: original, save: false)
            let restored = try readWirelessConfig(device)
            guard (0..<10).allSatisfy({ restored[$0][4..<19] == original[$0][4..<19] }) else {
                throw DeviceError.verification("The receiver's lighting configuration did not restore exactly.")
            }
            return
        }
        guard let original = musicConfig else { return }
        // After a failed restore, a later manual lighting choice must not be overwritten on quit.
        defer { musicConfig = nil; previousPreview = [] }
        guard let device, link == .wired else { throw DeviceError.notConnected }
        try writeWiredConfig(device, response: original)
        previewFrame = previousPreview
        if !previewFrame.isEmpty {
            try sendPreview()
            startPreviewTimer()
        }
    }

    private func enableDirectMode(_ device: IOHIDDevice) throws {
        let enable: [(UInt8, [UInt8])] = [(0x39,[0x20,0x06,0,1,0]),(0x3C,[0x20,1,0]),(0x39,[0x20,0x06,1,1,0])]
        for (id, data) in enable {
            try setReport(device, type: kIOHIDReportTypeFeature, id: CFIndex(id), bytes: F75Protocol.smallFeature(id: id, data: data))
        }
    }

    private func startPreviewTimer() {
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { try? self?.sendPreview() }
        }
    }

    private func sendPreview() throws {
        guard let device, !previewFrame.isEmpty else { return }
        try setReport(device, type: kIOHIDReportTypeFeature, id: 0x06, bytes: previewFrame)
    }

    private func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        previewFrame = []
    }

    private func readWiredConfig(_ device: IOHIDDevice) throws -> [UInt8] {
        try setReport(device, type: kIOHIDReportTypeFeature, id: 0x06, bytes: F75Protocol.configRead())
        var response = [UInt8](repeating: 0, count: F75Protocol.reportLength)
        response[0] = 0x06
        var length = response.count
        let result = response.withUnsafeMutableBytes {
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0x06, $0.bindMemory(to: UInt8.self).baseAddress!, &length)
        }
        guard result == kIOReturnSuccess, length >= 136 else { throw DeviceError.io("Read failed", result) }
        return response
    }

    private func writeWiredConfig(_ device: IOHIDDevice, response: [UInt8]) throws {
        var output = F75Protocol.configRead()
        output[1] = 0x04
        output.replaceSubrange(8..<136, with: response[8..<136])
        try setReport(device, type: kIOHIDReportTypeFeature, id: 0x06, bytes: output)
    }

    private func readWirelessConfig(_ device: IOHIDDevice) throws -> [[UInt8]] {
        guard let input else { throw DeviceError.noReply }
        input.clear()
        try setReport(device, type: kIOHIDReportTypeOutput, id: 0x13, bytes: F75Protocol.wirelessConfigRead())
        let deadline = Date().addingTimeInterval(1.5)
        var config: [Int: [UInt8]] = [:]
        while Date() < deadline, config.count < 10 {
            Thread.sleep(forTimeInterval: 0.005)
            for report in input.reports() where F75Protocol.validWirelessReport(report) && report[1] == 0x44 && report[2] == 0x0A && report[3] < 10 {
                config[Int(report[3])] = report
            }
        }
        guard config.count == 10 else { throw DeviceError.verification("Configuration read received \(config.count)/10 fragments; \(input.reports().count) input reports total. No configuration was written by this read.") }
        return (0..<10).map { config[$0]! }
    }

    private func writeWirelessConfig(_ device: IOHIDDevice, reports: [[UInt8]], save: Bool = true) throws {
        for source in reports {
            var report = source
            report[1] = 0x04
            report[19] = report.prefix(19).reduce(0, &+)
            try wirelessExchange(device, report: report)
        }
        if save {
            try wirelessExchange(device, report: F75Protocol.wirelessFrame(command: 0x0A, subcommand: 0x01, sequence: 0, payload: [0x04, 0x07]))
        }
    }

    #if F75_DIAGNOSTICS
    // Opt-in hardware check: change only lighting, then restore the saved configuration.
    func verifyReceiverTransport(readOnly: Bool = false) throws {
        guard let device, link == .wireless else { throw DeviceError.notConnected }
        let original = try readWirelessConfig(device)
        print("PASS: read all 10 configuration fragments on the dedicated callback thread")
        if readOnly { return }
        var test = original
        test[0][15] = 1
        test[4][7] = original[4][7] == 8 ? 7 : 8
        do {
            try writeWirelessConfig(device, reports: test)
            let actual = try readWirelessConfig(device)
            guard actual[0][15] == 1, actual[4][7] == test[4][7] else {
                throw DeviceError.verification("Diagnostic brightness read-back differed")
            }
            print("PASS: all 11 writes acknowledged; temporary brightness read back as \(actual[4][7])")
        } catch {
            try writeWirelessConfig(device, reports: original)
            throw error
        }
        try writeWirelessConfig(device, reports: original)
        let restored = try readWirelessConfig(device)
        guard (0..<10).allSatisfy({ restored[$0][4..<19] == original[$0][4..<19] }) else {
            throw DeviceError.verification("Diagnostic restoration read-back differed")
        }
        print("PASS: original configuration restored and all 10 fragments verified")
    }
    #endif

    private func wirelessExchange(_ device: IOHIDDevice, report: [UInt8]) throws {
        guard let input else { throw DeviceError.notConnected }
        input.clear()
        try setReport(device, type: kIOHIDReportTypeOutput, id: 0x13, bytes: report)
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            if input.reports().contains(where: { response in
                F75Protocol.validWirelessReport(response) && response[1...3] == report[1...3]
            }) { return }
            Thread.sleep(forTimeInterval: 0.002)
        }
        let headers = input.reports().map { $0.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ") }.joined(separator: "; ")
        throw DeviceError.verification(String(format: "Receiver did not acknowledge command 0x%02X, fragment %d (%d replies: %@). Transfer stopped.", report[1], report[3], input.reports().count, headers))
    }

    private func property(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    enum DeviceError: LocalizedError {
        case notConnected
        case malformedReport
        case noReply
        case emptyColors
        case wiredOnly
        case verification(String)
        case io(String, IOReturn)

        var errorDescription: String? {
            switch self {
            case let .verification(reason): reason
            case .notConnected: "No configurable AULA F75 is connected."
            case .malformedReport: "The app built an invalid HID report."
            case .noReply: "The F75 did not confirm the change. Reconnect it with the 2.4 GHz receiver or USB cable and try again."
            case .emptyColors: "Paint at least one key first."
            case .wiredOnly: "Key remapping requires the USB cable; the 2.4 GHz receiver does not expose the keymap feature report."
            case let .io(action, code): "\(action) (IOKit error \(code)). Try reconnecting the keyboard directly to the Mac."
            }
        }
    }
}

private final class HIDInputMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [[UInt8]] = []
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let device: IOHIDDevice
    private let finished = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?
    private var stopped = false

    init(device: IOHIDDevice) {
        self.device = device
        let started = DispatchSemaphore(value: 0)
        // HID callbacks must keep running during synchronous UI actions.
        Thread { [self] in
            let loop = CFRunLoopGetCurrent()!
            lock.lock(); runLoop = loop; lock.unlock()
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, result, _, _, reportID, report, length in
                // Never retain keyboard input reports; only configuration replies.
                guard result == kIOReturnSuccess, reportID == 0x13,
                      length == 19 || length == 20, let context else { return }
                let monitor = Unmanaged<HIDInputMonitor>.fromOpaque(context).takeUnretainedValue()
                var bytes = Array(UnsafeBufferPointer(start: report, count: length))
                if length == 19 { bytes.insert(0x13, at: 0) }
                monitor.append(bytes)
            }, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(device, loop, CFRunLoopMode.defaultMode.rawValue)
            started.signal()
            CFRunLoopRun()
            // IOKit keys registrations by context. nil would leave this callback
            // registered and call a freed monitor after the next Refresh.
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceUnscheduleFromRunLoop(device, loop, CFRunLoopMode.defaultMode.rawValue)
            finished.signal()
        }.start()
        started.wait()
    }

    deinit { buffer.deallocate() }

    func stop() {
        lock.lock()
        guard !stopped, let runLoop else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(runLoop) }
        CFRunLoopWakeUp(runLoop)
        finished.wait()
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        received.removeAll(keepingCapacity: true)
    }

    func reports() -> [[UInt8]] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    private func append(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        if received.count == 256 { received.removeFirst() }
        received.append(bytes)
    }
}
