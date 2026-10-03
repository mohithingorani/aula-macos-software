import Testing
import AVFoundation
@testable import AulaF75Mac

@Test func musicLevelsAndDirectFrames() {
    var envelope = MusicEnvelope()
    #expect(envelope.update(rms: 0, sensitivity: 1) == 0)
    #expect(envelope.update(rms: 0.001, sensitivity: 1) == 0)
    let quiet = envelope.update(rms: 0.05, sensitivity: 1)
    let loud = envelope.update(rms: 0.2, sensitivity: 1)
    #expect(loud > quiet)
    #expect(envelope.update(rms: 100, sensitivity: 4) == 1)
    let fading = envelope.update(rms: 0, sensitivity: 1)
    #expect(fading > 0 && fading < 1)
    for _ in 0..<30 { _ = envelope.update(rms: 0, sensitivity: 1) }
    #expect(envelope.level == 0)
    #expect(envelope.update(rms: .nan, sensitivity: 1) == 0)
    #expect(envelope.update(rms: .infinity, sensitivity: 1) == 0)
    var sensitive = MusicEnvelope()
    #expect(sensitive.update(rms: 0.05, sensitivity: 2) > quiet)
    var slow = MusicEnvelope()
    var fast = MusicEnvelope()
    _ = slow.update(rms: 1, sensitivity: 1)
    _ = fast.update(rms: 1, sensitivity: 1)
    _ = fast.update(rms: 0, sensitivity: 1, elapsed: 0.05)
    #expect(abs(slow.update(rms: 0, sensitivity: 1, elapsed: 0.1) - fast.update(rms: 0, sensitivity: 1, elapsed: 0.05)) < 0.000001)

    let color = RGB(red: 100, green: 200, blue: 50)
    let colors = MusicEnvelope.colors(level: 0.5, color: color)
    #expect(colors.count == F75Protocol.keys.flatMap { $0 }.count)
    let frame = F75Protocol.directFrame(colors)
    #expect(frame.count == 520)
    #expect(Array(frame.prefix(8)) == [6, 8, 0, 0, 1, 0, 122, 1])
    for key in F75Protocol.keys.flatMap({ $0 }) {
        let offset = 8 + key.index * 3
        #expect(Array(frame[offset..<(offset + 3)]) == [50, 100, 25])
    }
    #expect(MusicEnvelope.colors(level: 0, color: color).values.allSatisfy { $0 == RGB(red: 0, green: 0, blue: 0) })
    #expect(MusicEnvelope.colors(level: .nan, color: color).values.allSatisfy { $0 == RGB(red: 0, green: 0, blue: 0) })
    #expect(MusicEnvelope.colors(level: 2, color: color).values.allSatisfy { $0 == color })
    #expect(F75Protocol.directFrame([-1: color, 122: color]) == F75Protocol.directFrame([:]))
}

@Test func wirelessMusicPacketsAndConfigValidation() throws {
    // Exact cyan single-key frame from the OEM capture (LED 0x37).
    let cyan = RGB(red: 0, green: 255, blue: 255)
    let single = try F75Protocol.wirelessMusicFrames(color: cyan, indices: [55])
    #expect(single == [[0x13, 0x88, 1, 0, 0x15, 0, 255, 255, 1, 55, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xE7]])
    #expect(try F75Protocol.wirelessMusicFrames(color: cyan, indices: []) == [])
    #expect(try F75Protocol.wirelessMusicFrames(color: cyan, indices: [55, 55]) == single)
    #expect(throws: F75Protocol.ProtocolError.self) { try F75Protocol.wirelessMusicFrames(color: cyan, indices: [-1]) }
    #expect(throws: F75Protocol.ProtocolError.self) { try F75Protocol.wirelessMusicFrames(color: cyan, indices: [126]) }
    for count in [1, 10, 11, 80, 81, 126] {
        let frames = try F75Protocol.wirelessMusicFrames(color: .init(red: 0, green: 0, blue: 0), indices: Array(0..<count))
        var decoded: [UInt8] = []
        var index = 0
        while index < frames.count {
            let count = Int(frames[index][2])
            #expect(count <= 6)
            let message = frames[index..<(index + count)]
            var data: [UInt8] = []
            for (sequence, frame) in message.enumerated() {
                #expect(F75Protocol.validWirelessReport(frame))
                #expect(frame[1] == 0x88 && frame[2] == count && frame[3] == sequence)
                let length = Int(frame[4]) - 0x10
                #expect((1...14).contains(length))
                #expect(sequence == count - 1 || length == 14)
                data += frame[5..<(5 + length)]
            }
            #expect(Array(data.prefix(3)) == [0, 0, 0]) // Silence explicitly paints black; no guessed idle command.
            #expect(data.count == Int(data[3]) + 4)
            decoded += data.dropFirst(4)
            index += count
        }
        #expect(decoded == Array(0..<count).map { UInt8($0) }) // No truncated tail keys.
    }
    var config = Array(F75Protocol.wirelessApply(effect: .fixedOn, brightness: 6, speed: 2, colorful: false, color: cyan).prefix(10))
    for index in config.indices {
        config[index][1] = 0x44
        config[index][19] = config[index].prefix(19).reduce(0, &+)
    }
    #expect(F75Protocol.validWirelessConfig(config))
    #expect(!F75Protocol.validWirelessConfig(Array(config.dropLast())))
    config[9][5] = 0
    config[9][19] = config[9].prefix(19).reduce(0, &+)
    #expect(!F75Protocol.validWirelessConfig(config)) // Checksum alone cannot validate a config snapshot.
}

@Test func capturedStereoAudioLevel() throws {
    let output = MusicAudioOutput()
    #expect(output.latest().rms == 0)
    // ScreenCaptureKit supplies Float32 PCM. Exercise both buffer layouts.
    for interleaved in [false, true] {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        pcm.frameLength = 4
        for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
            let data = try #require(buffer.mData).assumingMemoryBound(to: Float.self)
            for index in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) {
                data[index] = index.isMultiple(of: 2) ? 0.25 : -0.25
            }
        }
        var description: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
                                               layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                               extensions: nil, formatDescriptionOut: &description) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                     makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
                                     sampleCount: 4, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                     sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
        let captured = try #require(sample)
        #expect(CMSampleBufferSetDataBufferFromAudioBufferList(captured, blockBufferAllocator: kCFAllocatorDefault,
                                                               blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                                                               bufferList: pcm.audioBufferList) == noErr)
        #expect(CMSampleBufferSetDataReady(captured) == noErr)
        output.receive(captured)
        #expect(abs(output.latest().rms - 0.25) < 0.0001)
        #expect(output.latest().failure == nil)
    }
}
