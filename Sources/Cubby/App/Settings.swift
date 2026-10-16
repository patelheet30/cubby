import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// UserDefaults-backed preferences (the SwiftUI views bind the same keys with @AppStorage).
enum Settings {
    static let d = UserDefaults.standard
    static let hotkeyChanged = Notification.Name("CubbyHotkeyChanged")

    static func register() {
        d.register(defaults: [
            "historyDays": 30, "soundEffects": false, "directPaste": true, "alwaysPlain": false,
            "ignoreConfidential": true, "ignoreTransient": true, "linkPreviews": true, "showDuringSharing": false,
            "ignoredApps": "", "hotkeyCode": kVK_ANSI_V, "hotkeyMods": cmdKey | shiftKey, "hotkeyLabel": "⇧⌘V", "pausedUntil": 0.0,
        ])
    }

    static var historyDays: Int { d.integer(forKey: "historyDays") }    // 0 = forever
    static var soundEffects: Bool { d.bool(forKey: "soundEffects") }
    static var directPaste: Bool { d.bool(forKey: "directPaste") }
    static var alwaysPlain: Bool { d.bool(forKey: "alwaysPlain") }
    static var ignoreConfidential: Bool { d.bool(forKey: "ignoreConfidential") }
    static var ignoreTransient: Bool { d.bool(forKey: "ignoreTransient") }
    static var linkPreviews: Bool { d.bool(forKey: "linkPreviews") }
    static var sharing: NSWindow.SharingType { d.bool(forKey: "showDuringSharing") ? .readOnly : .none }
    static var ignoredApps: [String] {
        get { d.string(forKey: "ignoredApps")!.split(separator: "\n").map(String.init) }
        set { d.set(newValue.joined(separator: "\n"), forKey: "ignoredApps") }
    }
    static var hotkey: (code: UInt32, mods: UInt32, label: String) {
        (UInt32(d.integer(forKey: "hotkeyCode")), UInt32(d.integer(forKey: "hotkeyMods")), d.string(forKey: "hotkeyLabel")!)
    }

    /// Capture pause: 0 = running, `.infinity` = until resumed.
    static var pausedUntil: Double {
        get { d.double(forKey: "pausedUntil") }
        set { d.set(newValue, forKey: "pausedUntil") }
    }
    static var isPaused: Bool { pausedUntil > Date().timeIntervalSince1970 }

    static let historyChoices: [(String, Int)] = [("Day", 1), ("Week", 7), ("Month", 30), ("Year", 365), ("Forever", 0)]
}

// MARK: window

/// Brings one of our ordinary windows forward. An accessory app may not take focus from a keypress
/// (only from a click), so we become a regular app while such a window is open and go back when it closes.
enum Foreground {
    static func show(_ w: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        // Cooperative activation can refuse a keypress-driven activate(); LaunchServices ("open -a") is always allowed.
        if !NSApp.isActive {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
                DispatchQueue.main.async { w.makeKeyAndOrderFront(nil) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            DispatchQueue.main.async {
                if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
}

final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Cubby Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
        }
        window.map(Foreground.show)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            PrivacyTab().tabItem { Label("Privacy", systemImage: "hand.raised") }
            ShortcutsTab().tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }
}

/// View-local state. (`@State` is a macro, and macro plugins only ship with Xcode, so we use an ObservableObject instead.)
final class TabState: ObservableObject {
    @Published var login = SMAppService.mainApp.status == .enabled
    @Published var pendingDays: Int?
    @Published var confirmErase = false
    @Published var selection: String?
    @Published var recording = false
    var monitor: Any?
}

struct GeneralTab: View {
    @StateObject private var ui = TabState()
    @AppStorage("soundEffects") private var sound = false
    @AppStorage("directPaste") private var direct = true
    @AppStorage("alwaysPlain") private var plain = false
    @AppStorage("historyDays") private var days = 30

    var body: some View {
        Form {
            Toggle("Open at login", isOn: $ui.login).onChange(of: ui.login) { _, on in
                do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch {
                    log("login item: \(error)"); ui.login = SMAppService.mainApp.status == .enabled
                }
            }
            Toggle("Sound when something is copied", isOn: $sound)
            Picker("Paste items", selection: $direct) {
                Text("Into the app you were in").tag(true)
                Text("To the clipboard only").tag(false)
            }
            if direct && !AXIsProcessTrusted() {
                HStack {
                    Text("Needs Accessibility permission.").foregroundStyle(.secondary)
                    Button("Grant…") { PasteboardWriter.askForDirectPaste() }
                }
            }
            Toggle("Always paste as plain text", isOn: $plain)
            Picker("Keep history for", selection: Binding(get: { days }, set: { new in
                if new != 0 && (days == 0 || new < days) { ui.pendingDays = new } else { days = new }
            })) {
                ForEach(Settings.historyChoices, id: \.1) { Text($0.0).tag($0.1) }
            }
            Button("Erase History…", role: .destructive) { ui.confirmErase = true }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clips older than this will be deleted now. Pinned clips are kept.",
                            isPresented: Binding(get: { ui.pendingDays != nil }, set: { if !$0 { ui.pendingDays = nil } })) {
            Button("Delete Older Clips", role: .destructive) {
                if let n = ui.pendingDays { days = n; Store.shared.trim(before: Date(timeIntervalSinceNow: -Double(n) * 86400)) }
                ui.pendingDays = nil
            }
        }
        .confirmationDialog("Erase all history? Pinned clips are kept.", isPresented: $ui.confirmErase) {
            Button("Erase History", role: .destructive) { Store.shared.eraseHistory() }
        }
    }
}

struct PrivacyTab: View {
    @StateObject private var ui = TabState()
    @AppStorage("ignoreConfidential") private var confidential = true
    @AppStorage("ignoreTransient") private var transient = true
    @AppStorage("linkPreviews") private var previews = true
    @AppStorage("showDuringSharing") private var sharing = false
    @AppStorage("ignoredApps") private var ignored = ""

    private var apps: [String] { ignored.split(separator: "\n").map(String.init) }

    var body: some View {
        Form {
            Toggle("Ignore passwords and other confidential copies", isOn: $confidential)
            Toggle("Ignore temporary copies made by apps", isOn: $transient)
            Toggle("Fetch titles and images for links", isOn: $previews)
            Toggle("Show the drawer during screen sharing", isOn: $sharing)
            Section("Never save copies from") {
                List(apps, id: \.self, selection: $ui.selection) { id in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
                            .resizable().frame(width: 16, height: 16)
                        Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent ?? id)
                    }
                }
                .frame(minHeight: 90)
                HStack {
                    Button("Add App…") { addApp() }
                    Button("Remove") { ignored = apps.filter { $0 != ui.selection }.joined(separator: "\n") }.disabled(ui.selection == nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addApp() {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.application]
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        let ids = p.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }.filter { !apps.contains($0) }
        ignored = (apps + ids).joined(separator: "\n")
    }
}

struct ShortcutsTab: View {
    @StateObject private var ui = TabState()
    @AppStorage("hotkeyLabel") private var label = "⇧⌘V"

    var body: some View {
        Form {
            LabeledContent("Open the drawer") {
                Button(ui.recording ? "Type a shortcut…" : label) { ui.recording ? stop() : start() }.frame(minWidth: 120)
            }
            Button("Reset to ⇧⌘V") { save(code: kVK_ANSI_V, mods: cmdKey | shiftKey, label: "⇧⌘V") }
            Section("In the drawer") {
                ForEach(Self.keys, id: \.0) { k in LabeledContent(k.0, value: k.1) }
            }
        }
        .formStyle(.grouped)
        .onDisappear { stop() }
    }

    static let keys = [("Paste", "↩"), ("Paste as plain text", "⇧↩"), ("Quick paste", "⌘1 – ⌘9"), ("Preview", "Space"),
                       ("Copy", "⌘C"), ("Delete / Undo", "⌫ / ⌘Z"), ("Next / previous list", "⇥ / ⇧⇥ or ⌘→ / ⌘←"),
                       ("New pinboard", "⇧⌘N"), ("New text clip", "⌘N"), ("Search", "just type, or ⌘F")]

    private func start() {
        ui.recording = true
        Hotkeys.shared.unregisterAll() // so the current shortcut can be typed into the recorder
        ui.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let f = e.modifierFlags
            guard !f.intersection([.command, .control, .option]).isEmpty else { NSSound.beep(); return nil }
            var mods = 0
            if f.contains(.command) { mods |= cmdKey }
            if f.contains(.shift) { mods |= shiftKey }
            if f.contains(.option) { mods |= optionKey }
            if f.contains(.control) { mods |= controlKey }
            let sym = (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "")
            save(code: Int(e.keyCode), mods: mods, label: sym + (e.charactersIgnoringModifiers ?? "?").uppercased())
            stop()
            return nil
        }
    }

    private func stop() {
        if let m = ui.monitor { NSEvent.removeMonitor(m) }
        ui.monitor = nil
        if ui.recording { ui.recording = false; NotificationCenter.default.post(name: Settings.hotkeyChanged, object: nil) }
    }

    private func save(code: Int, mods: Int, label: String) {
        Settings.d.set(code, forKey: "hotkeyCode")
        Settings.d.set(mods, forKey: "hotkeyMods")
        self.label = label
        NotificationCenter.default.post(name: Settings.hotkeyChanged, object: nil)
    }
}

// MARK: new text clip (⌘N)

final class NewTextWindow: NSObject, NSTextViewDelegate {
    static let shared = NewTextWindow()
    private var window: NSWindow?
    private let text = NSTextView()

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260), styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "New Text Clip"
            w.isReleasedWhenClosed = false
            let sv = NSScrollView()
            sv.documentView = text
            sv.hasVerticalScroller = true
            text.autoresizingMask = .width
            text.font = .systemFont(ofSize: 13)
            text.isRichText = false
            text.textContainerInset = NSSize(width: 6, height: 8)
            text.delegate = self
            let add = NSButton(title: "Add to History", target: self, action: #selector(add))
            add.keyEquivalent = "\r"
            add.keyEquivalentModifierMask = .command
            let hint = NSTextField(labelWithString: "⌘↩ to add")
            hint.textColor = .tertiaryLabelColor
            hint.font = .systemFont(ofSize: 11)
            let root = NSView()
            for v in [sv, add, hint] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
            NSLayoutConstraint.activate([
                sv.topAnchor.constraint(equalTo: root.topAnchor), sv.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                sv.trailingAnchor.constraint(equalTo: root.trailingAnchor), sv.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -12),
                add.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14), add.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
                hint.centerYAnchor.constraint(equalTo: add.centerYAnchor), hint.trailingAnchor.constraint(equalTo: add.leadingAnchor, constant: -10),
            ])
            w.contentView = root
            w.center()
            window = w
        }
        text.string = ""
        window.map(Foreground.show)
        window?.makeFirstResponder(text)
    }

    /// ⌘↩ adds (the text view would otherwise take it before the button's key equivalent).
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard NSApp.currentEvent?.modifierFlags.contains(.command) == true, NSApp.currentEvent?.keyCode == 36 else { return false }
        add()
        return true
    }

    @objc private func add() {
        let s = text.string
        guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return NSSound.beep() }
        let items = [PayloadItem(types: ["public.utf8-plain-text"], data: ["public.utf8-plain-text": Data(s.utf8)])]
        DispatchQueue.global(qos: .userInitiated).async {
            ClipboardWatcher.ingest(items, bundleID: Bundle.main.bundleIdentifier, appName: "Cubby", date: Date(), store: .shared)
        }
        window?.close()
    }
}
