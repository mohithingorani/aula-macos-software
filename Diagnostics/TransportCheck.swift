import Foundation

// swiftc -O -whole-module-optimization -swift-version 6 -D F75_DIAGNOSTICS Sources/AulaF75Mac/{F75Device,F75Protocol}.swift Diagnostics/TransportCheck.swift -o /private/tmp/aula-transport-check
@main
struct TransportCheck {
    @MainActor static func main() async {
        let keyboard = F75Device()
        keyboard.scan()
        print(keyboard.connection, keyboard.detail)
        do {
            if CommandLine.arguments.contains("--music") {
                // Opt-in, temporary live colors; uses the production Start/Stop paths.
                guard keyboard.connected, !keyboard.isWired else { throw F75Device.DeviceError.notConnected }
                try keyboard.beginMusicSync()
                do {
                    for frame in 0..<40 {
                        let deadline = ContinuousClock.now.advanced(by: .milliseconds(125))
                        let brightness = UInt8((frame % 8) * 30)
                        try await keyboard.sendMusicColor(RGB(red: 0, green: brightness, blue: brightness))
                        try await ContinuousClock().sleep(until: deadline)
                    }
                } catch {
                    try keyboard.endMusicSync()
                    throw error
                }
                try keyboard.endMusicSync()
                print("PASS: 40 live receiver frames sent; original configuration restored and read-back verified. Physical LED response still requires visual confirmation.")
            } else if CommandLine.arguments.contains("--read-only") {
                try keyboard.verifyReceiverTransport(readOnly: true)
            } else if CommandLine.arguments.contains("--green-respire") {
                try keyboard.apply(effect: .respire, brightness: 9, speed: 2, colorful: false, color: RGB(red: 0, green: 255, blue: 0))
                print("PASS: Respire configuration read-back; expected LEDs: green breathing. Visual confirmation required.")
            } else if CommandLine.arguments.contains("--lifecycle") {
                // Reproduce Refresh/onAppear replacing an existing callback context.
                for iteration in 1...30 {
                    keyboard.scan()
                    try keyboard.verifyReceiverTransport(readOnly: true)
                    print("PASS: refresh/read cycle \(iteration)")
                }
            } else {
                try keyboard.verifyReceiverTransport()
            }
        } catch {
            print("FAIL:", error.localizedDescription)
            exit(1)
        }
    }
}
