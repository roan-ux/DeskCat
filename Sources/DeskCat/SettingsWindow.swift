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

private struct SettingsView: View {
    let onLookChange: () -> Void
    let onRename: (String) -> Void

    @State private var look = Look.current
    @State private var name = Settings.name ?? ""
    @State private var roams = Settings.roamsOnItsOwn
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?

    var body: some View {
        Form {
            Section("Cat") {
                TextField("Name on the box", text: $name, prompt: Text("e.g. Mochi"))
                LabeledContent("Coat") { SwatchRow(swatches: Look.coats, selection: $look.coat) }
                LabeledContent("Eyes") { SwatchRow(swatches: Look.eyeColors, selection: $look.eyes) }
                Picker("Size", selection: $look.size) {
                    ForEach(CatSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Personality", selection: $look.personality) {
                    ForEach(Personality.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Box") {
                LabeledContent("Colour") { SwatchRow(swatches: Look.boxColors, selection: $look.box) }
            }
            Section("Behaviour") {
                Toggle("Wander out of the box on its own", isOn: $roams)
                Toggle("Open at login", isOn: $openAtLogin)
                if let loginNote {
                    Text(loginNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Reset look to defaults") { look = .standard }
            }
        }
        .formStyle(.grouped)
        // A grouped Form scrolls, so it has no height of its own; without one the window collapses to its title bar.
        .frame(width: 440, height: 560)
        .onChange(of: look) { newValue in
            Look.current = newValue
            onLookChange()
        }
        .onChange(of: name) { newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { onRename(String(trimmed.prefix(24))) }
        }
        .onChange(of: roams) { Settings.roamsOnItsOwn = $0 }
        .onChange(of: openAtLogin) { setOpenAtLogin($0) }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginNote = nil
        } catch {
            loginNote = "This works once DeskCat runs as an app (build it with scripts/make-app.sh and put it in Applications)."
            openAtLogin = SMAppService.mainApp.status == .enabled
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
