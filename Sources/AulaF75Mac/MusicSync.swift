import AVFoundation
import ScreenCaptureKit

// A level envelope, not tempo detection: fast attack and a short fade between beats.
struct MusicEnvelope {
    private(set) var level = 0.0

    mutating func update(rms: Double, sensitivity: Double, elapsed: Double = 0.05) -> Double {
        let input = rms.isFinite && sensitivity.isFinite ? max(0, rms) * max(0, sensitivity) : 0
        let target = min(1, max(0, (input - 0.005) * 4))
        let decay = pow(0.72, (elapsed.isFinite ? max(0, elapsed) : 0.05) / 0.05)
        level = target > level ? target : level * decay + target * (1 - decay)
        if level < 0.002 { level = 0 }
        return level
    }

    static func scaledColor(level: Double, color: RGB) -> RGB {
        let amount = level.isFinite ? min(1, max(0, level)) : 0
        return RGB(red: UInt8(Double(color.red) * amount),
                   green: UInt8(Double(color.green) * amount),
                   blue: UInt8(Double(color.blue) * amount))
    }

    static func colors(level: Double, color: RGB) -> [Int: RGB] {
        let scaled = scaledColor(level: level, color: color)
        return Dictionary(uniqueKeysWithValues: F75Protocol.keys.flatMap { $0 }.map { ($0.index, scaled) })
    }
}

@MainActor
final class MusicSync: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var level = 0.0
    @Published private(set) var message = "Play audio in any app, then start syncing."
    @Published var sensitivity = 1.0
    @Published var color = RGB(red: 80, green: 160, blue: 255)
    var isBusy: Bool { isRunning || isStarting || isStopping }

    private var stream: SCStream?
    private var output: MusicAudioOutput?
    private var animation: Task<Void, Never>?
    private var generation = 0
    private weak var keyboard: F75Device?

    func start(keyboard: F75Device) async {
        guard !isBusy else { return }
        guard keyboard.connected else {
            message = "Connect the USB cable or 2.4 GHz receiver, then click Refresh."
            return
        }
        self.keyboard = keyboard
        isStarting = true
        generation += 1
        let session = generation
        message = "Waiting for macOS audio capture access…"
        defer { isStarting = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard session == generation else {
                message = "Music Sync cancelled."
                return
            }
            guard let display = content.displays.first else {
                throw MusicError.noDisplay
            }
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48000
            configuration.channelCount = 2
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
            let output = MusicAudioOutput()
            let capture = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
                                   configuration: configuration, delegate: output)
            // Only audio has an output handler; no screen frames or audio are stored.
            try capture.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "aula.music.audio"))
            self.output = output
            stream = capture
            try await capture.startCapture()
            guard session == generation else {
                isStarting = false
                await stop()
                return
            }
            try keyboard.beginMusicSync()
            isRunning = true
            message = keyboard.isWired ? "Listening to Mac audio over USB. Keep this app open."
                : "Listening to Mac audio over 2.4 GHz (up to 8 updates/sec). Keep this app open."
            animation = Task { [weak self] in
                var envelope = MusicEnvelope()
                let clock = ContinuousClock()
                var previousUpdate = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled {
                    guard let self else { return }
                    let deadline = clock.now.advanced(by: .milliseconds(keyboard.isWired ? 50 : 125))
                    let sample = output.latest()
                    do {
                        if let failure = sample.failure { throw MusicError.capture(failure) }
                        let now = ProcessInfo.processInfo.systemUptime
                        self.level = envelope.update(rms: sample.rms, sensitivity: self.sensitivity, elapsed: now - previousUpdate)
                        previousUpdate = now
                        try await keyboard.sendMusicColor(MusicEnvelope.scaledColor(level: self.level, color: self.color))
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled else { return }
                        let reason = error.localizedDescription
                        await self.stop()
                        self.message = "Music Sync stopped: \(reason) \(self.message)"
                        return
                    }
                    do { try await clock.sleep(until: deadline) } catch { return }
                }
            }
        } catch {
            let reason = error.localizedDescription
            isStarting = false
            await stop()
            message = "Could not start Music Sync: \(reason) \(message) If access was denied, allow this app in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen it."
        }
    }

    func stop() async {
        guard !isStopping else { return }
        generation += 1
        // Let the in-flight permission/start request finish before stopping its stream.
        guard !isStarting else {
            message = "Cancelling audio capture…"
            return
        }
        isStopping = true
        animation?.cancel()
        animation = nil
        level = 0
        var failures: [String] = []
        do { try keyboard?.endMusicSync() } catch { failures.append("Lighting restoration failed: \(error.localizedDescription)") }
        if let stream {
            do { try await stream.stopCapture() } catch { failures.append("Audio capture stop failed: \(error.localizedDescription)") }
        }
        stream = nil
        output = nil
        isRunning = false
        isStopping = false
        message = failures.isEmpty ? "Stopped. Previous lighting restored." : failures.joined(separator: " ")
    }

    func shutdown() {
        generation += 1
        animation?.cancel()
        stream?.stopCapture(completionHandler: nil)
        do { try keyboard?.endMusicSync() } catch { NSLog("Music Sync restoration failed: %@", error.localizedDescription) }
    }

    private enum MusicError: LocalizedError {
        case noDisplay
        case capture(String)
        var errorDescription: String? {
            switch self {
            case .noDisplay: "macOS did not provide a display for system audio capture."
            case .capture(let reason): reason
            }
        }
    }
}

// Retain the peak between animation updates so slower wireless frames don't miss beats.
final class MusicAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var rms = 0.0
    private var receivedAt = 0.0
    private var failure: String?

    func latest() -> (rms: Double, failure: String?) {
        lock.lock(); defer { rms = 0; lock.unlock() }
        return (ProcessInfo.processInfo.systemUptime - receivedAt < 0.25 ? rms : 0, failure)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock(); defer { lock.unlock() }
        failure = error.localizedDescription
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        receive(sampleBuffer)
    }

    func receive(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let description = sampleBuffer.formatDescription,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            lock.lock(); defer { lock.unlock() }
            failure = "macOS supplied an unsupported audio format."
            return
        }
        do {
            let level = try sampleBuffer.withAudioBufferList { buffers, _ -> Double in
                var sum = 0.0
                var count = 0
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                                      count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                    for sample in samples where sample.isFinite {
                        let value = Double(sample)
                        sum += value * value
                        count += 1
                    }
                }
                return count == 0 ? 0 : sqrt(sum / Double(count))
            }
            lock.lock(); defer { lock.unlock() }
            rms = max(rms, level)
            receivedAt = ProcessInfo.processInfo.systemUptime
        } catch {
            lock.lock(); defer { lock.unlock() }
            failure = "Could not read captured audio: \(error.localizedDescription)"
        }
    }
}
