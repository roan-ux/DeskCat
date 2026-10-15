import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var cat: CatController?
    private let settings = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let cat = CatController()
        cat.menuProvider = { [weak self] in self?.makeMenu() }
        cat.start()
        self.cat = cat
        settings.onLookChange = { [weak cat] in cat?.applyLook() }
        settings.onRename = { [weak cat] name in cat?.name = name }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "DeskCat") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "🐈‍⬛"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        // First launch: ask for a name to put on the box.
        if Settings.name == nil {
            perform(#selector(rename), with: nil, afterDelay: 0.4)
        }
    }

    // MARK: Menu (menu bar icon + right-click on the box or cat)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fill(menu)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        fill(menu)
        return menu
    }

    private func fill(_ menu: NSMenu) {
        guard let cat else { return }
        menu.addItem(NSMenuItem(title: cat.name, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        add(to: menu, cat.isHome ? "Let \(cat.name) out" : "Call \(cat.name) back to the box", #selector(toggleOut))
        add(to: menu, "Settings…", #selector(openSettings), key: ",")
        add(to: menu, "Rename…", #selector(rename))
        add(to: menu, "Wander on its own", #selector(toggleRoam)).state = Settings.roamsOnItsOwn ? .on : .off
        add(to: menu, "Move box to the corner", #selector(resetBox))
        menu.addItem(.separator())
        add(to: menu, "Quit DeskCat", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)
    }

    @discardableResult
    private func add(to menu: NSMenu, _ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        menu.addItem(item)
        return item
    }

    // MARK: Actions

    @objc private func toggleOut() {
        guard let cat else { return }
        if cat.isHome { cat.letOut() } else { cat.callHome() }
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func toggleRoam() {
        Settings.roamsOnItsOwn.toggle()
    }

    @objc private func resetBox() {
        cat?.resetBoxPosition()
    }

    @objc private func rename() {
        guard let cat else { return }
        let alert = NSAlert()
        alert.messageText = "What's your cat called?"
        alert.informativeText = "The name goes on the box."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = Settings.name ?? ""
        field.placeholderString = "e.g. Mochi"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        // Accessory apps aren't frontmost by default; without this the field can't take typing.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            cat.name = String(name.prefix(24))
        }
    }
}
