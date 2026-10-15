import AppKit

@main
@MainActor
enum DeskCatApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu-bar-only app: no Dock icon, not in the Cmd-Tab switcher.
        app.setActivationPolicy(.accessory)
        // NSApplication holds its delegate weakly, so keep it alive for the run loop.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
