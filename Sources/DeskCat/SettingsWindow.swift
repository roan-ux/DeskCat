import AppKit
import ServiceManagement
import SwiftUI

/// The Settings window (menu bar cat → Settings…). Changes apply live.
@MainActor
final class SettingsWindowController {
    var onLookChange: (() -> Void)?
    var onRename: ((String) -> Void)?
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = SettingsView(
                onLookChange: { [weak self] in self?.onLookChange?() },
                onRename: { [weak self] name in self?.onRename?(name) })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "DeskCat Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // A menu-bar app isn't frontmost by default; bring the window forward so it takes typing.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The window's editable state. An ObservableObject rather than @State so DeskCat builds with
/// the Command Line Tools alone, which don't ship SwiftUI's macro plugin.
@MainActor
private final class SettingsModel: ObservableObject {
    @Published var look = Look.current
    @Published var name = Settings.name ?? ""
    @Published var roams = Settings.roamsOnItsOwn
    @Published var soundOn = Settings.soundOn
    @Published var volume = Settings.soundVolume
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginNote: String?
}

private struct SettingsView: View {
    let onLookChange: () -> Void
    let onRename: (String) -> Void

    @StateObject private var m = SettingsModel()

    var body: some View {
        Form {
            Section("Cat") {
                TextField("Name on the box", text: $m.name, prompt: Text("e.g. Mochi"))
                LabeledContent("Coat") { SwatchRow(swatches: Look.coats, selection: $m.look.coat) }
                LabeledContent("Eyes") { SwatchRow(swatches: Look.eyeColors, selection: $m.look.eyes) }
                Picker("Size", selection: $m.look.size) {
                    ForEach(CatSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Personality", selection: $m.look.personality) {
                    ForEach(Personality.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Box") {
                LabeledContent("Colour") { SwatchRow(swatches: Look.boxColors, selection: $m.look.box) }
            }
            Section("Behaviour") {
                Toggle("Wander out of the box on its own", isOn: $m.roams)
                Toggle("Open at login", isOn: $m.openAtLogin)
                if let loginNote = m.loginNote {
                    Text(loginNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Sound") {
                Toggle("Purring and meows", isOn: $m.soundOn)
                LabeledContent("Volume") {
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $m.volume, in: 0...1)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }
                .disabled(!m.soundOn)
            }
            HStack {
                Spacer()
                Button("Reset look to defaults") { m.look = .standard }
            }
        }
        .formStyle(.grouped)
        // A grouped Form scrolls, so it has no height of its own; without one the window collapses to its title bar.
        .frame(width: 440, height: 660)
        .onChange(of: m.look) { newValue in
            Look.current = newValue
            onLookChange()
        }
        .onChange(of: m.name) { newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { onRename(String(trimmed.prefix(24))) }
        }
        .onChange(of: m.roams) { Settings.roamsOnItsOwn = $0 }
        .onChange(of: m.soundOn) { Settings.soundOn = $0 }
        .onChange(of: m.volume) { Settings.soundVolume = $0 }
        .onChange(of: m.openAtLogin) { setOpenAtLogin($0) }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            m.loginNote = nil
        } catch {
            m.loginNote = "This works once DeskCat runs as an app (build it with scripts/make-app.sh and put it in Applications)."
            m.openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Preset colour dots plus a colour well for anything else.
private struct SwatchRow: View {
    let swatches: [Swatch]
    @Binding var selection: RGB

    var body: some View {
        HStack(spacing: 10) {
            ForEach(swatches, id: \.name) { swatch in
                let selected = swatch.color.hex == selection.hex
                Button { selection = swatch.color } label: {
                    Circle()
                        .fill(Color(swatch.color))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                        .padding(3)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(selected ? 1 : 0))
                }
                .buttonStyle(.plain)
                .help(swatch.name)
                .accessibilityLabel(swatch.name)
            }
            ColorPicker("Custom", selection: Binding(get: { Color(selection) }, set: { selection = RGB($0) }),
                        supportsOpacity: false)
                .labelsHidden()
                .help("Pick any colour")
        }
    }
}

private extension Color {
    init(_ rgb: RGB) { self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b) }
}

private extension RGB {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(ns.redComponent, ns.greenComponent, ns.blueComponent)
    }
}
