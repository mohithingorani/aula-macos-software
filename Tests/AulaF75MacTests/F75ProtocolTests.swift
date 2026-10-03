import Testing
@testable import AulaF75Mac

@Test func wiredFrames() throws {
    let read = F75Protocol.configRead()
    #expect(read.count == 520)
    #expect(Array(read.prefix(8)) == [0x06, 0x84, 0, 0, 1, 0, 0x80, 0])

    var response = read
    response[1] = 0x84
    response[55] = 0xAB
    let write = try F75Protocol.configWrite(from: response, effect: .flashAway, brightness: 9, speed: 4, colorful: true)
    #expect(Array(write.prefix(8)) == [0x06, 0x04, 0, 0, 1, 0, 0x80, 0])
    #expect(write[18] == 4)
    #expect(write[72] == 9)
    #expect(write[73] == 0x47)
    #expect(write[55] == 0xAB)
}

@Test func colorFrame() {
    let report = F75Protocol.colorProfile(RGB(red: 1, green: 2, blue: 3))
    #expect(report[0] == 0x06)
    #expect(report[1] == 0x0A)
    #expect(Array(report[29...31]) == [1, 2, 3])
    #expect(Array(report[0x202...0x203]) == [0x5A, 0xA5])

    for effect in Effect.allCases where effect.supportsCustomColor {
        let color = RGB(red: 19, green: 71, blue: 213)
        let wired = F75Protocol.colorProfile(color, effect: effect)
        let frames = F75Protocol.wirelessApply(effect: effect, brightness: 7, speed: 2, colorful: false, color: color)
        let palette = frames.filter { $0[1] == 0x09 }.flatMap { Array($0[5..<19]) }
        let offset = effect.rawValue * 7 * 3
        #expect(Array(wired[(8 + offset)..<(11 + offset)]) == [19, 71, 213])
        #expect(Array(palette[offset..<(offset + 3)]) == [19, 71, 213])
        #expect(frames.allSatisfy(F75Protocol.validWirelessReport))
    }
    #expect(!Effect.rainbow.supportsCustomColor)
    #expect(Effect.respire.supportsCustomColor)
}

@Test func wirelessFrames() {
    let frames = F75Protocol.wirelessApply(effect: .fixedOn, brightness: 6, speed: 2, colorful: false, color: RGB(red: 9, green: 8, blue: 7))
    #expect(frames.count == 48)
    #expect(frames[0][15] == 1)
    #expect(frames[4][7] == 6)
    #expect(frames[11][12...14] == [9, 8, 7])
    #expect(frames.last?[1] == 0x0A)
    #expect(frames.allSatisfy { $0.count == 20 && $0[19] == $0.prefix(19).reduce(0, &+) })

    let read = F75Protocol.wirelessConfigRead()
    #expect(Array(read.prefix(4)) == [0x13, 0x44, 0x01, 0])
    var reply = [UInt8](repeating: 0, count: 20)
    reply[0] = 0x13; reply[1] = 0x44; reply[2] = 0x0A; reply[15] = 7
    #expect(F75Protocol.wirelessEffect(from: [reply]) == 7)
}

@Test func advancedFrames() {
    #expect(Effect.flashAway.hardwareID == 4)
    #expect(Effect.colorfulWaterfall.hardwareID == 16)

    let frames = F75Protocol.wirelessPerKey([0: RGB(red: 1, green: 2, blue: 3)])
    #expect(frames.count == 39)
    #expect(frames[0][15] == 21)
    #expect(frames[10][5] == 1)
    #expect(frames[19][5] == 2)
    #expect(frames[28][5] == 3)

    let keymap = F75Protocol.keymap(layer: 1, mappings: [9: HIDOutput(page: 0, usage: 4)])
    #expect(Array(keymap.prefix(6)) == [6, 3, 1, 0, 1, 0])
    #expect(keymap[0x08 + 4 * 9] == 0)
    #expect(keymap[0x0B + 4 * 9] == 4)
    #expect(Array(keymap.suffix(2)) == [0x5A, 0xA5])
}

@Test func preserveSettingsAndValidateReplies() {
    let color = RGB(red: 1, green: 2, blue: 3)
    var original = Array(F75Protocol.wirelessApply(effect: .fixedOn, brightness: 6, speed: 2, colorful: false, color: color).prefix(10))
    original[0][8] = 4 // Existing debounce setting.
    original[1][15] = 20 // Existing sleep setting.
    original[2][12] = 0xAB // Unrelated firmware field.
    for index in original.indices {
        original[index][1] = 0x44
        original[index][19] = original[index].prefix(19).reduce(0, &+)
    }
    for effect in Effect.allCases {
        let output = F75Protocol.wirelessApply(effect: effect, brightness: 9, speed: 4, colorful: true, color: color, config: original)
        #expect(output[0][15] == effect.rawValue)
        #expect(output[0][8] == 4)
        #expect(output[1][15] == 20)
        #expect(output[2][12] == 0xAB)
        #expect(output.allSatisfy(F75Protocol.validWirelessReport))
    }
    let custom = F75Protocol.wirelessPerKey([0: color], config: original)
    #expect(custom[0][8] == 4)
    #expect(custom[1][15] == 20)
    var corrupt = original[0]
    corrupt[8] ^= 1
    #expect(!F75Protocol.validWirelessReport(corrupt))
    #expect(!F75Protocol.validWirelessReport(Array(original[0].dropLast())))
    #expect(!F75Protocol.validWirelessReport([]))
}
