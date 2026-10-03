import Foundation

struct RGB: Equatable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
}

struct HIDOutput: Equatable, Hashable, Sendable {
    var page: UInt8
    var usage: UInt8
}

struct KeySpec: Identifiable, Sendable {
    var id: Int { index }
    let label: String
    let index: Int
    let width: Double
}

enum Effect: Int, CaseIterable, Identifiable, Sendable {
    case off = 0, fixedOn, respire, rainbow, flashAway, raindrops, rainbowWheel, ripplesShining
    case starsTwinkle, shadowDisappear, retroSnake, neonStream, reaction, sineWave, retinueScanning
    case rotatingWindmill, colorfulWaterfall, blossoming, rotatingStorm

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .fixedOn: "Fixed on"
        case .respire: "Respire"
        case .rainbow: "Rainbow"
        case .flashAway: "Flash away"
        case .raindrops: "Raindrops"
        case .rainbowWheel: "Rainbow wheel"
        case .ripplesShining: "Ripples shining"
        case .starsTwinkle: "Stars twinkle"
        case .shadowDisappear: "Shadow disappear"
        case .retroSnake: "Retro snake"
        case .neonStream: "Neon stream"
        case .reaction: "Reaction"
        case .sineWave: "Sine wave"
        case .retinueScanning: "Retinue scanning"
        case .rotatingWindmill: "Rotating windmill"
        case .colorfulWaterfall: "Colorful waterfall"
        case .blossoming: "Blossoming"
        case .rotatingStorm: "Rotating storm"
        }
    }

    // KB.ini columns are "hw effect ...": the FIRST is the wire ID;
    // the second selects the Windows application's preview animation.
    var hardwareID: Int { rawValue }

    // OEM KB.ini: last column of LedOpt is custom-color support.
    var supportsCustomColor: Bool { ![.off, .rainbow, .rotatingWindmill, .colorfulWaterfall, .blossoming].contains(self) }

    // Seven RGB colors per effect, preceded by a reserved 21-byte block.
    var paletteOffset: Int { hardwareID * 21 }
}

enum F75Protocol {
    static let wiredVendor = 0x258A
    static let wiredProduct = 0x010C
    static let wirelessVendor = 0x3554
    static let wirelessProduct = 0xFA09
    static let reportID: UInt8 = 0x06
    static let reportLength = 520

    static func configRead() -> [UInt8] {
        frame(command: 0x84, address: [0, 0, 1, 0], length: 0x80)
    }

    static func configWrite(from response: [UInt8], effect: Effect, brightness: Int, speed: Int, colorful: Bool) throws -> [UInt8] {
        guard response.count >= 136, response[0] == reportID, response[1] == 0x84 else {
            throw ProtocolError.invalidConfig
        }
        var edited = response
        edited[17] = 0
        edited[18] = UInt8(effect.hardwareID)
        if effect != .off {
            let offset = 64 + 2 * effect.hardwareID
            edited[offset] = UInt8(clamping: brightness)
            edited[offset + 1] = UInt8((min(max(speed, 0), 4) << 4) | (colorful ? 7 : 0))
        }
        var output = frame(command: 0x04, address: [0, 0, 1, 0], length: 0x80)
        output.replaceSubrange(8..<136, with: edited[8..<136])
        return output
    }

    static func colorProfile(_ color: RGB, effect: Effect = .fixedOn) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: reportLength)
        output[0] = reportID
        output[1] = 0x0A
        output[7] = 0x02
        let offset = 8 + effect.paletteOffset
        output.replaceSubrange(offset..<(offset + 3), with: [color.red, color.green, color.blue])
        output[0x202] = 0x5A
        output[0x203] = 0xA5
        return output
    }

    static func wirelessApply(effect: Effect, brightness: Int, speed: Int, colorful: Bool, color: RGB, config: [[UInt8]]? = nil) -> [[UInt8]] {
        let sources = config.map { $0.map { Array($0[4..<19]) } } ?? wirelessConfigTemplate
        var frames = sources.enumerated().map { sequence, source -> [UInt8] in
            var payload = source
            if sequence == 0 {
                payload[10] = 0
                payload[11] = UInt8(effect.hardwareID)
                payload[13] = 1
            }
            if effect != .off {
                let location = wirelessParameterLocation(effect.hardwareID)
                if sequence == location.fragment {
                    payload[location.offset] = UInt8(clamping: brightness)
                    payload[location.offset + 1] = UInt8((min(max(speed, 0), 4) << 4) | (colorful ? 7 : 0))
                }
            }
            return wirelessFrame(command: 0x04, subcommand: 0x0A, sequence: UInt8(sequence), payload: payload)
        }

        for sequence in 0..<37 {
            var payload = sequence < paletteTemplate.count
                ? paletteTemplate[sequence]
                : [UInt8](repeating: 0, count: 15)
            payload[0] = sequence == 36 ? 0x08 : 0x0E
            // Fragment payload byte zero is a length, followed by 14 data bytes.
            // RGB may straddle fragments: don't hard-code the Fixed-on slot.
            if effect.supportsCustomColor {
                for (channel, value) in [color.red, color.green, color.blue].enumerated() {
                    let offset = effect.paletteOffset + channel
                    if offset / 14 == sequence { payload[1 + offset % 14] = value }
                }
            }
            if sequence == 36 {
                payload[3] = 0x5A
                payload[4] = 0xA5
            }
            frames.append(wirelessFrame(command: 0x09, subcommand: 0x25, sequence: UInt8(sequence), payload: payload))
        }
        frames.append(wirelessFrame(command: 0x0A, subcommand: 0x01, sequence: 0, payload: [0x04, 0x07]))
        return frames
    }

    static func wirelessConfigRead() -> [UInt8] {
        wirelessFrame(command: 0x44, subcommand: 0x01, sequence: 0, payload: [])
    }

    static func wirelessPerKey(_ colors: [Int: RGB], config: [[UInt8]]? = nil) -> [[UInt8]] {
        let sources = config.map { $0.map { Array($0[4..<19]) } } ?? wirelessConfigTemplate
        var frames = sources.enumerated().map { sequence, source -> [UInt8] in
            var payload = source
            if sequence == 0 {
                payload[10] = 0
                payload[11] = 21
                payload[13] = 1
            }
            return wirelessFrame(command: 0x04, subcommand: 0x0A, sequence: UInt8(sequence), payload: payload)
        }
        let planes = (0..<3).map { channel in
            (0..<126).map { index -> UInt8 in
                guard let color = colors[index] else { return 0 }
                return [color.red, color.green, color.blue][channel]
            }
        }
        var sequence = 0
        for plane in planes {
            for page in 0..<9 {
                var payload = [UInt8](repeating: 0, count: 15)
                payload[0] = 0x0E
                for byte in 0..<14 { payload[byte + 1] = plane[page * 14 + byte] }
                frames.append(wirelessFrame(command: 0x02, subcommand: 0x1C, sequence: UInt8(sequence), payload: payload))
                sequence += 1
            }
        }
        frames.append(wirelessFrame(command: 0x02, subcommand: 0x1C, sequence: UInt8(sequence), payload: [0x06, 0, 0, 0x5A, 0xA5]))
        frames.append(wirelessFrame(command: 0x0A, subcommand: 0x01, sequence: 0, payload: [0x04, 0x07]))
        return frames
    }

    static func colorTable(_ colors: [Int: RGB]) -> [UInt8] {
        var output = frame(command: 0x0A, address: [0, 0, 1, 0], length: 0x0200)
        for (index, color) in colors where index >= 0 && index < 128 {
            let offset = 8 + index * 4
            output[offset] = color.red
            output[offset + 1] = color.green
            output[offset + 2] = color.blue
        }
        return output
    }

    static func directFrame(_ colors: [Int: RGB]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: reportLength)
        output[0] = 0x06
        output[1] = 0x08
        output[4] = 0x01
        output[6] = 122
        output[7] = 0x01
        for (index, color) in colors where index >= 0 && index < 122 {
            let offset = 8 + index * 3
            output[offset] = color.red
            output[offset + 1] = color.green
            output[offset + 2] = color.blue
        }
        return output
    }

    // Receiver live RGB, captured from the OEM driver: keylux/docs/PROTOCOL.md.
    // Each message is at most 84 bytes: RGB + count + up to 80 LED indices.
    static func wirelessMusicFrames(color: RGB, indices: [Int] = keys.flatMap { $0 }.map(\.index)) throws -> [[UInt8]] {
        guard indices.allSatisfy({ (0..<126).contains($0) }) else { throw ProtocolError.invalidLEDIndex }
        let indices = Array(Set(indices)).sorted()
        var frames: [[UInt8]] = []
        for start in stride(from: 0, to: indices.count, by: 80) {
            let group = indices[start..<min(start + 80, indices.count)]
            let data = [color.red, color.green, color.blue, UInt8(group.count)] + group.map { UInt8($0) }
            let count = (data.count + 13) / 14
            for sequence in 0..<count {
                let chunk = Array(data[(sequence * 14)..<min((sequence + 1) * 14, data.count)])
                frames.append(wirelessFrame(command: 0x88, subcommand: UInt8(count), sequence: UInt8(sequence),
                                            payload: [0x10 + UInt8(chunk.count)] + chunk))
            }
        }
        return frames
    }

    static func smallFeature(id: UInt8, data: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: reportLength)
        output[0] = id
        output.replaceSubrange(1..<(1 + min(data.count, reportLength - 1)), with: data.prefix(reportLength - 1))
        return output
    }

    static func keymap(layer: Int, mappings: [Int: HIDOutput]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: reportLength)
        output[0] = 0x06; output[1] = 0x03; output[2] = UInt8(clamping: layer)
        output[4] = 0x01; output[7] = 0xFF
        for (index, mapping) in mappings where index >= 0 && 0x0B + 4 * index < 518 {
            let offset = 0x08 + 4 * index
            output[offset] = mapping.page
            output[offset + 3] = mapping.usage
        }
        output[518] = 0x5A; output[519] = 0xA5
        return output
    }

    static let keys: [[KeySpec]] = [
        [("Esc",0,1),("F1",12,1),("F2",18,1),("F3",24,1),("F4",30,1),("F5",36,1),("F6",42,1),("F7",48,1),("F8",54,1),("F9",60,1),("F10",66,1),("F11",72,1),("F12",78,1),("End",88,1)],
        [("`",1,1),("1",7,1),("2",13,1),("3",19,1),("4",25,1),("5",31,1),("6",37,1),("7",43,1),("8",49,1),("9",55,1),("0",61,1),("-",67,1),("=",73,1),("Bksp",79,2),("Del",85,1)],
        [("Tab",2,1.5),("Q",8,1),("W",14,1),("E",20,1),("R",26,1),("T",32,1),("Y",38,1),("U",44,1),("I",50,1),("O",56,1),("P",62,1),("[",68,1),("]",74,1),("\\",80,1.5),("PgUp",86,1)],
        [("Caps",3,1.75),("A",9,1),("S",15,1),("D",21,1),("F",27,1),("G",33,1),("H",39,1),("J",45,1),("K",51,1),("L",57,1),(";",63,1),("'",69,1),("Enter",81,2.25)],
        [("LShift",4,2.25),("Z",10,1),("X",16,1),("C",22,1),("V",28,1),("B",34,1),("N",40,1),("M",46,1),(",",52,1),(".",58,1),("/",64,1),("RShift",70,2.25),("↑",82,1)],
        [("LCtrl",5,1.25),("Win",11,1.25),("LAlt",17,1.25),("Space",35,6.25),("RAlt",53,1.25),("Fn",59,1.25),("←",77,1),("↓",83,1),("→",89,1),("PgDn",87,1)],
    ].map { row in row.map { KeySpec(label: $0.0, index: $0.1, width: $0.2) } }

    static let remapActions: [(String, HIDOutput)] = {
        var result: [(String, HIDOutput)] = [("Disabled", HIDOutput(page: 0, usage: 0))]
        for (offset, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            result.append((String(letter), HIDOutput(page: 0, usage: UInt8(4 + offset))))
        }
        for (label, usage) in zip(["1","2","3","4","5","6","7","8","9","0"], Array(0x1E...0x27)) {
            result.append((label, HIDOutput(page: 0, usage: UInt8(usage))))
        }
        result += [("Enter",.init(page:0,usage:0x28)),("Esc",.init(page:0,usage:0x29)),("Backspace",.init(page:0,usage:0x2A)),("Tab",.init(page:0,usage:0x2B)),("Space",.init(page:0,usage:0x2C))]
        for number in 1...12 { result.append(("F\(number)", HIDOutput(page: 0, usage: UInt8(0x39 + number)))) }
        result += [("Play/Pause",.init(page:2,usage:0xCD)),("Previous",.init(page:2,usage:0xB6)),("Next",.init(page:2,usage:0xB5)),("Mute",.init(page:2,usage:0xE2)),("Volume down",.init(page:2,usage:0xEA)),("Volume up",.init(page:2,usage:0xE9))]
        return result
    }()

    static func defaultBaseMap() -> [Int: HIDOutput] {
        var result: [Int: HIDOutput] = [:]
        let byName = Dictionary(uniqueKeysWithValues: remapActions.map { ($0.0.uppercased(), $0.1) })
        let special: [String: UInt8] = [
            "`":0x35,"-":0x2D,"=":0x2E,"[":0x2F,"]":0x30,"\\":0x31,";":0x33,"'":0x34,",":0x36,".":0x37,"/":0x38,
            "DEL":0x4C,"END":0x4D,"PGUP":0x4B,"PGDN":0x4E,"CAPS":0x39,"ENTER":0x28,"BKSP":0x2A,"TAB":0x2B,"SPACE":0x2C,
            "↑":0x52,"↓":0x51,"←":0x50,"→":0x4F,"LCTRL":0xE0,"LSHIFT":0xE1,"LALT":0xE2,"WIN":0xE3,"RSHIFT":0xE5,"RALT":0xE6,
        ]
        for key in keys.flatMap({ $0 }) {
            let name = key.label.uppercased()
            if let output = byName[name] { result[key.index] = output }
            else if let usage = special[name] { result[key.index] = HIDOutput(page: 0, usage: usage) }
            else if key.label == "Fn" { result[key.index] = HIDOutput(page: 0, usage: 0) }
        }
        return result
    }

    static func wirelessEffect(from reports: [[UInt8]]) -> Int? {
        guard let report = reports.first(where: {
            $0.count == 20 && $0[0] == 0x13 && $0[1] == 0x44 && $0[2] == 0x0A && $0[3] == 0
        }) else { return nil }
        return Int(report[15])
    }

    static func validWirelessReport(_ report: [UInt8]) -> Bool {
        report.count == 20 && report[0] == 0x13 && report[19] == report.prefix(19).reduce(0, &+)
    }

    static func validWirelessConfig(_ reports: [[UInt8]]) -> Bool {
        guard reports.count == 10 else { return false }
        return reports.enumerated().allSatisfy { sequence, report in
            validWirelessReport(report) && report[1] == 0x44 && report[2] == 0x0A && report[3] == sequence
                && report[4] == (sequence == 9 ? 2 : 14)
        } && reports[9][5...6] == [0x5A, 0xA5]
    }

    static func wirelessFrame(command: UInt8, subcommand: UInt8, sequence: UInt8, payload: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 20)
        output[0] = 0x13
        output[1] = command
        output[2] = subcommand
        output[3] = sequence
        output.replaceSubrange(4..<(4 + min(payload.count, 15)), with: payload.prefix(15))
        output[19] = output.prefix(19).reduce(0, &+)
        return output
    }

    private static func frame(command: UInt8, address: [UInt8], length: UInt16) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: reportLength)
        output[0] = reportID
        output[1] = command
        output.replaceSubrange(2..<6, with: address)
        output[6] = UInt8(length & 0xFF)
        output[7] = UInt8(length >> 8)
        return output
    }

    private static func wirelessParameterLocation(_ effect: Int) -> (fragment: Int, offset: Int) {
        switch effect {
        case 1...6: (4, 3 + (effect - 1) * 2)
        default: (5 + (effect - 7) / 7, 1 + ((effect - 7) % 7) * 2)
        }
    }

    enum ProtocolError: LocalizedError {
        case invalidConfig
        case invalidLEDIndex
        var errorDescription: String? {
            switch self {
            case .invalidConfig: "The keyboard returned an invalid configuration report."
            case .invalidLEDIndex: "A live lighting frame contains an invalid LED index."
            }
        }
    }

    private static let wirelessConfigTemplate: [[UInt8]] = [
        [0x0E,0,3,3,1,0,0,4,4,7,0,0,0x20,3,0],
        [0x0E,1,0,0,0,1,0,2,1,0,0xFF,0x0A,0,0,0],
        [0x0E,1,0,4,1,0,0,0,0,0,0,0,0,0,0],
        [0x0E,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
        [0x0E,0xFF,0xFF,4,0x47,4,0x47,4,0x47,4,0x47,4,0x47,4,0x47],
        [0x0E,4,0x47,4,0x47,4,0x47,4,0x47,4,0x47,4,0x47,4,0x47],
        [0x0E,4,0x47,4,0x47,4,0x47,4,0x47,4,0x37,4,0x37,4,0x37],
        [0x0E,7,0x47,7,0x47,7,0x44,7,0x44,7,0x44,7,0x44,7,0x44],
        [0x0E,7,0x44,7,0x44,4,4,4,4,4,4,4,4,4,4],
        [2,0x5A,0xA5,0,0,0,0,0,0,0,0,0,0,0,0],
    ]

    private static let paletteTemplate: [[UInt8]] = {
        let a: [UInt8] = [0x0E,0,0xFF,0xFF,0xFF,0,0xFF,0,0xFF,0,0xFF,0xFF,0xFF,0xFF,0xFF]
        let b: [UInt8] = [0x0E,0xFF,0,0,0,0xFF,0,0,0,0xFF,0xFF,0xFF,0,0xFF,0]
        let c: [UInt8] = [0x0E,0xFF,0,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0,0,0,0xFF,0,0]
        var result = [[UInt8](repeating: 0, count: 15), [0x0E,0,0,0,0,0,0,0,0xFF,0,0,0,0xFF,0,0]]
        while result.count < 21 { result.append([a, b, c][(result.count - 2) % 3]) }
        return result
    }()
}
