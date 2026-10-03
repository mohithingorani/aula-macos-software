import SwiftUI

@main
struct AulaF75MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("AULA F75", id: "main") { ContentView() }
            .defaultSize(width: 1040, height: 720)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        // Launch Services can treat installed and dist copies as different apps.
        // Only the earliest instance may open a window and use the receiver.
        let first = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { !$0.isTerminated }
            .min {
                let lhs = $0.launchDate ?? .distantPast
                let rhs = $1.launchDate ?? .distantPast
                return lhs == rhs ? $0.processIdentifier < $1.processIdentifier : lhs < rhs
            }
        guard let first, first.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        first.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApplication.shared.terminate(nil)
    }
}

struct ContentView: View {
    @StateObject private var keyboard = F75Device()
    @StateObject private var music = MusicSync()
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle().fill(keyboard.connected ? .green : .orange).frame(width: 11, height: 11)
                VStack(alignment: .leading, spacing: 3) {
                    Text(keyboard.connection).font(.headline)
                    Text(keyboard.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if keyboard.needsPermission { Button("Allow Access") { keyboard.requestPermission() } }
                Button("Refresh") { keyboard.scan() }.disabled(music.isBusy)
            }
            .padding(18)

            Divider()

            TabView {
                LightingView(keyboard: keyboard, report: report).disabled(music.isBusy).tabItem { Label("Lighting", systemImage: "lightbulb") }
                MusicView(keyboard: keyboard, music: music).tabItem { Label("Music", systemImage: "waveform") }
                PerKeyView(keyboard: keyboard, report: report).disabled(music.isBusy).tabItem { Label("Per-Key", systemImage: "paintpalette") }
                RemapView(keyboard: keyboard, report: report).disabled(music.isBusy).tabItem { Label("Keys", systemImage: "keyboard") }
                MacroView().tabItem { Label("Macros", systemImage: "record.circle") }
                SettingsView(keyboard: keyboard, report: report).disabled(music.isBusy).tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .padding(14)
        }
        .frame(minWidth: 900, minHeight: 620)
        .onAppear { keyboard.scan() }
        .onDisappear { Task { await music.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in music.shutdown() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            Task { await music.stop() }
        }
        .alert("AULA F75", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "Unknown error") }
    }

    private func report(_ work: () throws -> Void) {
        do { try work() } catch { self.error = error.localizedDescription }
    }
}

private struct MusicView: View {
    @ObservedObject var keyboard: F75Device
    @ObservedObject var music: MusicSync
    @State private var color = Color(red: 80.0 / 255, green: 160.0 / 255, blue: 1)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Music Sync").font(.title2.bold())
                Text("Pulse your keyboard lights with Spotify, YouTube, or audio from any Mac app.")
                KeyboardPreview(colors: MusicEnvelope.colors(level: music.level, color: music.color), fallback: .black)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Keyboard lighting preview")
                LabeledContent("Audio level") {
                    ProgressView(value: music.level).frame(width: 300).accessibilityLabel("Music level")
                }
                LabeledContent("Sensitivity") {
                    Slider(value: $music.sensitivity, in: 0.25...4).frame(width: 300).accessibilityLabel("Music sensitivity")
                    Text(music.sensitivity, format: .number.precision(.fractionLength(1))).monospacedDigit()
                }
                ColorPicker("Light color", selection: $color, supportsOpacity: false)
                    .onChange(of: color) { value in
                        let rgb = NSColor(value).usingColorSpace(.deviceRGB) ?? .white
                        music.color = RGB(red: UInt8(clamping: Int(rgb.redComponent * 255)),
                                          green: UInt8(clamping: Int(rgb.greenComponent * 255)),
                                          blue: UInt8(clamping: Int(rgb.blueComponent * 255)))
                    }
                Text("Works over USB or the 2.4 GHz receiver. Wireless updates are slower. macOS will ask for screen/system audio capture access. Nothing is recorded or uploaded. Protected audio may not be available.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(music.message).font(.callout).textSelection(.enabled)
                Spacer()
                HStack {
                    if !keyboard.connected { Text("Connect USB or the 2.4 GHz receiver, then click Refresh.").foregroundStyle(.orange) }
                    Spacer()
                    if music.isBusy {
                        Button(music.isStopping ? "Stopping…" : "Stop Sync") { Task { await music.stop() } }
                            .disabled(music.isStopping)
                    } else {
                        Button("Start Music Sync") { Task { await music.start(keyboard: keyboard) } }
                            .buttonStyle(.borderedProminent).disabled(!keyboard.connected)
                    }
                }
            }.padding(12)
        }
    }
}

private struct LightingView: View {
    let keyboard: F75Device
    let report: (() throws -> Void) -> Void
    @State private var effect = Effect.fixedOn
    @State private var brightness = 7.0
    @State private var speed = 2.0
    @State private var colorful = false
    @State private var color = Color.white

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            List(Effect.allCases.filter { $0 != .off }, selection: $effect) {
                Text($0.title).tag($0)
            }.frame(width: 230)

            VStack(alignment: .leading, spacing: 22) {
                Text(effect.title).font(.title2.bold())
                KeyboardPreview(colors: [:], fallback: color)
                LabeledContent("Brightness") { Slider(value: $brightness, in: 0...9, step: 1).frame(width: 300); Text("\(Int(brightness))").monospacedDigit() }
                LabeledContent("Speed") { Slider(value: $speed, in: 0...4, step: 1).frame(width: 300); Text("\(Int(speed))").monospacedDigit() }
                LabeledContent("Color") {
                    ColorPicker("Effect color", selection: $color, supportsOpacity: false)
                        .labelsHidden().disabled(!effect.supportsCustomColor || colorful)
                }
                if effect.supportsCustomColor {
                    Toggle("Colorful animation (ignores selected color)", isOn: $colorful)
                } else {
                    Text("This effect is multicolor-only; the keyboard does not support a selected color for it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack {
                    Button("Lights Off") { run(.off) }.disabled(!keyboard.connected)
                    Spacer()
                    Button("Apply Lighting") { run(effect) }.buttonStyle(.borderedProminent).disabled(!keyboard.connected)
                }
            }.padding(.top, 8)
        }
    }

    private func run(_ selected: Effect) {
        report {
            let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
            try keyboard.apply(effect: selected, brightness: Int(brightness), speed: Int(speed), colorful: colorful || !selected.supportsCustomColor,
                               color: RGB(red: UInt8(clamping: Int(ns.redComponent * 255)), green: UInt8(clamping: Int(ns.greenComponent * 255)), blue: UInt8(clamping: Int(ns.blueComponent * 255))))
        }
    }
}

private struct PerKeyView: View {
    let keyboard: F75Device
    let report: (() throws -> Void) -> Void
    @State private var paint = Color.red
    @State private var colors: [Int: RGB] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Custom per-key lighting").font(.title2.bold())
                Spacer()
                ColorPicker("Paint", selection: $paint, supportsOpacity: false)
                Button("Fill All") { fillAll() }
                Button("Clear") { colors.removeAll() }
            }
            Text("Choose a color, then paint keys. USB uses a live direct-mode preview; 2.4 GHz stores the map on the keyboard.").font(.caption).foregroundStyle(.secondary)
            KeyboardEditor(colors: colors) { colors[$0] = rgb(paint) }
            Spacer()
            HStack {
                Text("\(colors.count) keys painted").foregroundStyle(.secondary)
                Spacer()
                Button("Apply Per-Key Colors") { report { try keyboard.applyPerKey(colors) } }
                    .buttonStyle(.borderedProminent).disabled(!keyboard.connected || colors.isEmpty)
            }
        }.padding(12)
    }

    private func fillAll() { let value = rgb(paint); colors = Dictionary(uniqueKeysWithValues: F75Protocol.keys.flatMap { $0 }.map { ($0.index, value) }) }
    private func rgb(_ color: Color) -> RGB {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        return RGB(red: UInt8(clamping: Int(ns.redComponent * 255)), green: UInt8(clamping: Int(ns.greenComponent * 255)), blue: UInt8(clamping: Int(ns.blueComponent * 255)))
    }
}

private struct RemapView: View {
    let keyboard: F75Device
    let report: (() throws -> Void) -> Void
    @State private var layer = 0
    @State private var selected = 0
    @State private var base = F75Protocol.defaultBaseMap()
    @State private var fn: [Int: HIDOutput] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Key assignment").font(.title2.bold())
                Picker("Layer", selection: $layer) { Text("Default").tag(0); Text("Fn").tag(1) }.pickerStyle(.segmented).frame(width: 220)
                Spacer()
                Text(keyboard.isWired ? "USB ready" : "Connect the USB cable to apply keymaps").foregroundStyle(keyboard.isWired ? .green : .secondary)
            }
            KeyboardSelector(selected: selected) { selected = $0 }
            Divider()
            HStack {
                Text("Selected: \(keyName(selected))").frame(width: 160, alignment: .leading)
                Picker("Assignment", selection: assignment) {
                    ForEach(F75Protocol.remapActions, id: \.1) { Text($0.0).tag($0.1) }
                }.frame(width: 260)
                Spacer()
                Button("Restore Layer") { if layer == 0 { base = F75Protocol.defaultBaseMap() } else { fn = [:] } }
                Button("Apply \(layer == 0 ? "Default" : "Fn") Layer") {
                    report { try keyboard.applyKeymap(layer: layer, mappings: layer == 0 ? base : fn) }
                }.buttonStyle(.borderedProminent).disabled(!keyboard.isWired)
            }
            if layer == 1 { Text("Only assigned Fn keys are enabled in this layer. Review the full layer before applying.").font(.caption).foregroundStyle(.orange) }
        }.padding(12)
    }

    private var assignment: Binding<HIDOutput> { Binding(get: { (layer == 0 ? base : fn)[selected] ?? .init(page: 0, usage: 0) }, set: { if layer == 0 { base[selected] = $0 } else { fn[selected] = $0 } }) }
    private func keyName(_ index: Int) -> String { F75Protocol.keys.flatMap { $0 }.first { $0.index == index }?.label ?? "Key \(index)" }
}

private struct MacroStep: Identifiable, Codable {
    var id = UUID()
    var key = "A"
    var delay = 50
}

private struct MacroView: View {
    @State private var name = "Macro 1"
    @State private var steps: [MacroStep] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Macro editor").font(.title2.bold())
            Text("The official driver stores key down/up and delay events. Hardware upload is disabled until its undocumented macro directory format is verified; this editor saves profiles locally without risking the keyboard firmware.").font(.caption).foregroundStyle(.secondary)
            TextField("Macro name", text: $name).frame(width: 280)
            Table($steps) {
                TableColumn("Key") { $step in TextField("Key", text: $step.key) }
                TableColumn("Delay (ms)") { $step in TextField("Delay", value: $step.delay, format: .number) }
                TableColumn("") { step in Button(role: .destructive) { steps.removeAll { $0.id == step.id } } label: { Image(systemName: "trash") } }.width(44)
            }
            HStack {
                Button("Add Step") { steps.append(MacroStep()) }
                Button("Save Locally") { save() }.disabled(steps.isEmpty)
                Spacer()
                Text("Keyboard upload: protocol verification pending").foregroundStyle(.orange)
            }
        }.padding(12)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(steps) { UserDefaults.standard.set(data, forKey: "macro.\(name)") }
    }
}

private struct SettingsView: View {
    let keyboard: F75Device
    let report: (() throws -> Void) -> Void
    @State private var sleep = 300
    @State private var debounce = 1

    var body: some View {
        Form {
            Section("Keyboard") {
                Picker("Sleep after", selection: $sleep) {
                    ForEach([60,90,120,180,240,300,600,900,1200], id: \.self) { Text("\($0 / 60)m\($0 % 60 == 0 ? "" : " \($0 % 60)s")").tag($0) }
                }
                Picker("Debounce", selection: $debounce) { ForEach(1...5, id: \.self) { Text("\($0) ms").tag($0) } }
                HStack {
                    Button("Apply Sleep Timer") { report { try keyboard.setSleep(seconds: sleep) } }.disabled(!keyboard.connected)
                    Button("Apply Debounce") { report { try keyboard.setDebounce(milliseconds: debounce) } }.disabled(!keyboard.connected)
                }
            }
            Section("Recovery") {
                Text("Factory reset: hold Fn + Esc on the keyboard for about 5 seconds. This hardware shortcut is safer than overwriting unknown firmware fields.")
                Text("Bluetooth carries normal keystrokes only. Use USB or the 2.4 GHz receiver for configuration.")
            }
        }.formStyle(.grouped)
    }
}

private struct KeyboardPreview: View {
    let colors: [Int: RGB]
    let fallback: Color
    var body: some View { KeyboardEditor(colors: colors, fallback: fallback) { _ in } }
}

private struct KeyboardEditor: View {
    let colors: [Int: RGB]
    var fallback: Color = Color(nsColor: .controlColor)
    let select: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(F75Protocol.keys.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5) {
                    ForEach(row) { key in
                        Button(key.label) { select(key.index) }
                            .buttonStyle(.plain).frame(width: 34 * key.width, height: 32)
                            .background(keyColor(key.index), in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.16)))
                    }
                }
            }
        }
    }
    private func keyColor(_ index: Int) -> Color {
        guard let color = colors[index] else { return fallback }
        return Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255)
    }
}

private struct KeyboardSelector: View {
    let selected: Int
    let select: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(F75Protocol.keys.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5) {
                    ForEach(row) { key in
                        Button(key.label) { select(key.index) }.buttonStyle(.plain).frame(width: 34 * key.width, height: 32)
                            .background(selected == key.index ? Color.accentColor : Color(nsColor: .controlColor), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
    }
}
