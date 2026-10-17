import AppKit

/// Owns the drawer window: placement, show/hide/toggle, slide animation, keyboard routing.
final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    private let panel: DrawerPanel
    private let drawer = DrawerView()
    private let preview = PreviewPanel()
    private var refreshTimer: Timer?
    private(set) var isShown = false

    override init() {
        panel = DrawerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .mainMenu // 24: above normal and floating windows, below menus
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the drawer layer draws its own
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none // no system zoom; we slide the drawer ourselves
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let root = NSView()
        root.addSubview(drawer)
        panel.contentView = root
        panel.onEscape = { [weak self] in self?.escape() }
        panel.onType = { [weak self] text in self?.drawer.search.begin(with: text) }
        drawer.search.onEscapeWhenEmpty = { [weak self] in self?.escape() }
        drawer.list.table.onEscape = { [weak self] in self?.escape() }
        drawer.onPreview = { [weak self] in self?.togglePreview() }
        drawer.onSelectionChange = { [weak self] in
            guard let self, self.preview.isVisible else { return }
            DispatchQueue.main.async { self.updatePreview() } // after the table has scrolled to the new row
        }
        // Open windows inside the click/keypress itself: macOS only lets us become active while handling user input.
        drawer.onNewText = { [weak self] in NewTextWindow.shared.show(); self?.hide() }
        drawer.onSettings = { [weak self] in SettingsWindow.shared.show(); self?.hide() }
        drawer.list.table.onType = { [weak self] text in self?.drawer.search.begin(with: text) }
        panel.onCommand = { [weak self] key, shift in
            guard let t = self?.drawer.list.table else { return false }
            switch (key, shift) {
            case ("f", false): t.onFind()
            case ("n", false): t.onNewText()
            case ("n", true): t.onNewPinboard()
            case ("m", false): t.onMerge()
            default: return false
            }
            return true
        }
        drawer.onPaste = { [weak self] clips, plain in self?.paste(clips, plain: plain) }
        drawer.onPasteText = { [weak self] text in
            guard let self else { return }
            PasteboardWriter.write(text: text)
            self.deliver(from: self.drawer.screenRect)
        }
    }

    func toggle() { isShown ? hide() : show() }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        panel.sharingType = Settings.sharing
        panel.setFrame(Theme.windowFrame(visible: screen.visibleFrame), display: false)
        drawer.frame = Theme.drawerFrame(windowSize: panel.frame.size)
        isShown = true

        panel.orderFrontRegardless()
        panel.makeKey()
        drawer.resetForShow()

        let layer = drawer.layer!
        layer.removeAllAnimations()
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        let slide = CASpringAnimation(keyPath: "transform.translation.x")
        slide.fromValue = offscreenX
        slide.toValue = 0
        slide.mass = 1
        slide.stiffness = 520
        slide.damping = 42
        slide.duration = slide.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12
        layer.add(slide, forKey: "slide")
        layer.add(fade, forKey: "fade")
        // Keeps "4m" / "Today" honest while the drawer stays open.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.drawer.reload(keepSelection: true) }
        log("drawer shown on \(screen.localizedName)")
    }

    /// Puts the clips on the pasteboard, closes the drawer, then types ⌘V into the app you were in
    /// (or, without Accessibility permission, leaves them copied and says so).
    func paste(_ clips: [Clip], plain: Bool) {
        let rect = drawer.screenRect
        guard PasteboardWriter.write(clips, plain: plain || Settings.alwaysPlain) else { return drawer.toast("Couldn't read that clip") }
        deliver(from: rect)
    }

    /// The pasteboard is ready: close the drawer, then ⌘V into the app you were in (or say it's copied).
    private func deliver(from rect: NSRect) {
        let direct = Settings.directPaste && PasteboardWriter.canDirectPaste
        hide {
            if direct { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { PasteboardWriter.typeCommandV() } }
        }
        if !Settings.directPaste {
            Toast.shared.show("Copied", in: rect)
        } else if !direct {
            Toast.shared.show("Copied — press ⌘V to paste", action: ("Paste for me…", PasteboardWriter.askForDirectPaste), in: rect)
        }
    }

    /// Esc closes the preview first, then the drawer.
    private func escape() { preview.isVisible ? preview.hide() : hide() }

    private func togglePreview() { preview.isVisible ? preview.hide() : updatePreview() }

    private func updatePreview() {
        guard isShown, let clip = drawer.list.selectedClips.first, let card = drawer.list.screenRect(of: clip.id) else { return preview.hide() }
        preview.show(clip, card: card, drawer: drawer.screenRect, sharing: Settings.sharing)
    }

    func hide(then done: @escaping () -> Void = {}) {
        guard isShown else { return done() }
        isShown = false
        preview.hide()
        refreshTimer?.invalidate()
        let layer = drawer.layer!
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !self.isShown else { return } // re-shown mid-animation
            self.panel.orderOut(nil)
            layer.removeAllAnimations()
            done()
        }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = 0
        slide.toValue = offscreenX
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        for a in [slide, fade] {
            a.duration = 0.14
            a.timingFunction = CAMediaTimingFunction(name: .easeIn)
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: a.keyPath)
        }
        CATransaction.commit()
    }

    /// Far enough right that the drawer is fully clipped by the window's right edge.
    private var offscreenX: CGFloat { Theme.drawerWidth + Theme.inset + 4 }

    // Clicking elsewhere or switching apps takes key away: close, like a menu.
    func windowDidResignKey(_ notification: Notification) { hide() }
}

/// Borderless, non-activating, but able to take key so the drawer gets typing without stealing focus from the app you're in.
final class DrawerPanel: NSPanel {
    var onEscape: () -> Void = {}
    var onType: (String) -> Void = { _ in }
    /// Drawer shortcuts that must work whether the list or the search field has focus (⌘F, ⌘N, ⇧⌘N).
    var onCommand: (String, Bool) -> Bool = { _, _ in false }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onEscape() }

    /// We never own the menu bar (non-activating), so the Edit menu's shortcuts don't reach us. Route them by hand.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if mods == .command || mods == [.command, .shift] {
            let shift = mods.contains(.shift)
            let action: String? = switch event.charactersIgnoringModifiers?.lowercased() {
            case "c" where !shift: "copy:"
            case "v" where !shift: "paste:"
            case "x" where !shift: "cut:"
            case "a" where !shift: "selectAll:"
            case "z": shift ? "redo:" : "undo:"
            default: nil
            }
            if let action, NSApp.sendAction(Selector(action), to: nil, from: self) { return true }
            if let key = event.charactersIgnoringModifiers?.lowercased(), onCommand(key, shift) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control])
        if event.keyCode == 53 { return onEscape() } // Esc
        if mods.isEmpty, let chars = event.characters, Self.isPrintable(chars) { return onType(chars) }
        super.keyDown(with: event)
    }

    static func isPrintable(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }
    }
}
