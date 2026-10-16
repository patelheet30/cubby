import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var housekeepingTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.register()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refreshStatusIcon()
        NSApp.mainMenu = Self.mainMenu()

        registerHotkey()
        NotificationCenter.default.addObserver(forName: Settings.hotkeyChanged, object: nil, queue: .main) { [weak self] _ in self?.registerHotkey() }

        ClipboardWatcher.shared.start()
        Store.shared.purge() // anything deleted last session is past undo
        housekeeping()
        if Settings.d.integer(forKey: "thumbnailVersion") < 3 { // v2: 1024 px thumbnails, v3: image files are image clips
            DispatchQueue.global(qos: .utility).async {
                Store.shared.reclassifyImages()
                DispatchQueue.main.async { Settings.d.set(3, forKey: "thumbnailVersion") }
            }
        }
        housekeepingTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.housekeeping() }

        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) } // screenshot testing
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { PanelController.shared.show() }
        }
    }

    private func registerHotkey() {
        Hotkeys.shared.unregisterAll()
        let k = Settings.hotkey
        Hotkeys.shared.register(keyCode: k.code, modifiers: k.mods) { PanelController.shared.toggle() }
    }

    private func refreshStatusIcon() {
        statusItem.button?.image = MenuBarIcon.image(paused: Settings.isPaused)
    }

    private func buildMenu() {
        menu.removeAllItems()
        let show = ActionItem("Show Clipboard") { PanelController.shared.toggle() }
        show.toolTip = Settings.hotkey.label
        menu.addItem(show)
        menu.addItem(ActionItem("New Text Clip…") { NewTextWindow.shared.show() })
        menu.addItem(.separator())
        if Settings.isPaused {
            let until = Settings.pausedUntil == .infinity ? "until resumed"
                : "until " + Date(timeIntervalSince1970: Settings.pausedUntil).formatted(date: .omitted, time: .shortened)
            let info = NSMenuItem(title: "Capture paused \(until)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
            menu.addItem(ActionItem("Resume Capture", key: "") { [weak self] in self?.pause(nil) })
        } else {
            let pause = NSMenuItem(title: "Pause Capture", action: nil, keyEquivalent: "")
            pause.submenu = NSMenu()
            for (title, minutes) in [("For 15 Minutes", 15.0), ("For 1 Hour", 60), ("For 8 Hours", 480)] {
                pause.submenu?.addItem(ActionItem(title, key: "") { [weak self] in self?.pause(minutes * 60) })
            }
            pause.submenu?.addItem(ActionItem("Until Resumed", key: "") { [weak self] in self?.pause(.infinity) })
            menu.addItem(pause)
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("About Cubby", key: "") { NSApp.activate(); NSApp.orderFrontStandardAboutPanel(nil) })
        menu.addItem(ActionItem("Settings…", key: ",") { SettingsWindow.shared.show() })
        menu.addItem(ActionItem("Quit Cubby", key: "q") { NSApp.terminate(nil) })
    }

    /// nil resumes; otherwise seconds (or .infinity).
    private func pause(_ seconds: Double?) {
        Settings.pausedUntil = seconds.map { $0 == .infinity ? .infinity : Date().timeIntervalSince1970 + $0 } ?? 0
        refreshStatusIcon()
        if let s = seconds, s != .infinity {
            DispatchQueue.main.asyncAfter(deadline: .now() + s + 1) { [weak self] in self?.refreshStatusIcon() }
        }
    }

    /// Hidden while we're an accessory app, but it gives the Settings and New Text windows ⌘C/⌘V/⌘W/⌘Q.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = NSMenu(title: title)
            items.forEach { top.submenu?.addItem($0) }
            main.addItem(top)
        }
        func item(_ t: String, _ sel: String, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: Selector(sel), keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        add("Cubby", [item("Quit Cubby", "terminate:", "q")])
        add("Edit", [item("Undo", "undo:", "z"), item("Redo", "redo:", "z", [.command, .shift]), .separator(),
                     item("Cut", "cut:", "x"), item("Copy", "copy:", "c"), item("Paste", "paste:", "v"), item("Select All", "selectAll:", "a")])
        add("Window", [item("Close", "performClose:", "w")])
        return main
    }

    /// Left click toggles the drawer; right click (or ⌃-click) shows the menu.
    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            buildMenu()
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            PanelController.shared.toggle()
        }
    }

    /// History capacity (days; 0 = forever, set from Settings later) and the ⌘Z window for deletes.
    private func housekeeping() {
        let days = Settings.historyDays
        if days > 0 { Store.shared.trim(before: Date(timeIntervalSinceNow: -Double(days) * 86400)) }
        Store.shared.purge(before: Date(timeIntervalSinceNow: -600))
    }

}
