import AppKit

/// The glass drawer: pinboard rail on the left; title, search, card list and hints on the right.
/// Reads from the store and performs every clip/pinboard action (pasting itself is `onPaste`, owned by the controller).
final class DrawerView: NSView {
    enum ListID: Equatable { case history, board(Int64) }

    let search = SearchField()
    let list = ClipList()
    var onPaste: ([Clip], Bool) -> Void = { _, _ in }
    var onPreview: () -> Void = {}
    var onSelectionChange: () -> Void = {}
    var onNewText: () -> Void = {}
    var onSettings: () -> Void = {}
    var store = Store.shared

    private let rail = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let moreButton = IconButton(symbol: "ellipsis", tip: "More")
    private let filterButton = IconButton(symbol: "line.3.horizontal.decrease", tip: "Filters (⌘F)")
    private let tray = FilterTray()
    private var listUnderSearch: NSLayoutConstraint!
    private var listUnderTray: NSLayoutConstraint!
    private(set) var filter = Filter()
    private let hints = HintBar()
    private let empty = EmptyState()
    private var railButtons: [(ListID, RailButton)] = []
    private var editor: InlineEditor?
    private var undo: (() -> Void)?

    private(set) var current: ListID = .history
    private(set) var pinboards: [Pinboard] = []
    private var query = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Theme.radius
        layer?.cornerCurve = .continuous
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 20
        layer?.shadowOffset = CGSize(width: -2, height: -4)

        let glass = Self.makeGlass()
        let railBG = RailBackground()
        rail.orientation = .vertical
        rail.spacing = 8
        rail.alignment = .centerX

        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .tertiaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let titleRow = NSStackView(views: [titleLabel, countLabel, spacer,
                                           filterButton, moreButton])
        titleRow.spacing = 8
        titleRow.alignment = .firstBaseline
        titleRow.setCustomSpacing(6, after: titleLabel)
        moreButton.target = self
        moreButton.action = #selector(moreClicked)
        filterButton.target = self
        filterButton.action = #selector(filterClicked)

        let gear = IconButton(symbol: "gearshape", tip: "Settings (⌘,)")
        gear.target = self
        gear.action = #selector(gearClicked)
        tray.isHidden = true
        for v in [glass, railBG, rail, gear, titleRow, search, tray, list, hints, empty] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let p = Theme.padding, railW = Theme.railWidth
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            railBG.leadingAnchor.constraint(equalTo: leadingAnchor), railBG.topAnchor.constraint(equalTo: topAnchor),
            railBG.bottomAnchor.constraint(equalTo: bottomAnchor), railBG.widthAnchor.constraint(equalToConstant: railW),
            rail.centerXAnchor.constraint(equalTo: railBG.centerXAnchor), rail.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            gear.centerXAnchor.constraint(equalTo: railBG.centerXAnchor), gear.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            titleRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: railW + p + 2),
            titleRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p + 4),
            titleRow.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: railW + 12),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            search.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 10),
            list.leadingAnchor.constraint(equalTo: leadingAnchor, constant: railW),
            list.trailingAnchor.constraint(equalTo: trailingAnchor),
            tray.leadingAnchor.constraint(equalTo: search.leadingAnchor, constant: 2),
            tray.trailingAnchor.constraint(equalTo: search.trailingAnchor, constant: -2),
            tray.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 2),
            list.bottomAnchor.constraint(equalTo: hints.topAnchor, constant: -4),
            hints.leadingAnchor.constraint(equalTo: leadingAnchor, constant: railW + p + 2),
            hints.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            hints.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            hints.heightAnchor.constraint(equalToConstant: Theme.hintHeight),
            empty.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: list.centerYAnchor, constant: -20),
        ])
        listUnderSearch = list.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 4)
        listUnderTray = list.topAnchor.constraint(equalTo: tray.bottomAnchor, constant: 2)
        listUnderSearch.isActive = true
        tray.onChange = { [weak self] f in self?.setFilter(f) }
        hints.set(keys: [("↩", "Paste"), ("⇧↩", "Plain"), ("Space", "Preview"), ("⇥", "Lists")], trailing: "")
        search.onChange = { [weak self] q in self?.searchChanged(q) }
        search.onBackspaceEmpty = { [weak self] in self?.removeLastFilter() }
        search.onMoveDown = { [weak self] in self?.focusList() }

        let t = list.table
        t.onTab = { [weak self] back in self?.cycleList(back: back) }
        t.onActivate = { [weak self] plain in self?.paste(plain: plain) }
        t.onQuick = { [weak self] n, plain in
            guard let self, self.list.clips.indices.contains(n - 1) else { return }
            self.onPaste([self.list.clips[n - 1]], plain)
        }
        t.onCopy = { [weak self] in self?.copy(self?.list.selectedClips ?? []) }
        t.onDelete = { [weak self] in self?.delete(self?.list.selectedClips ?? []) }
        t.onUndo = { [weak self] in self?.performUndo() }
        t.onNewPinboard = { [weak self] in self?.newPinboard(pinning: []) }
        t.onFind = { [weak self] in self?.filterClicked() }
        t.onPreview = { [weak self] in self?.onPreview() }
        t.onNewText = { [weak self] in self?.onNewText() }
        list.onSelectionChange = { [weak self] in self?.onSelectionChange() }
        list.menuProvider = { [weak self] clips in self?.clipMenu(clips) ?? NSMenu() }
        list.onCardAction = { [weak self] clip, action, view in self?.cardAction(clip, action, view) }
        list.onReorder = { [weak self] ids in
            guard let self, case .board(let b) = self.current else { return }
            self.store.reorder(board: b, ids)
        }
        NotificationCenter.default.addObserver(forName: Store.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.reload(keepSelection: true)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Theme.radius, cornerHeight: Theme.radius, transform: nil)
    }

    /// The drawer's frame on screen (for the toast), valid even while hidden.
    var screenRect: NSRect { window?.convertToScreen(convert(bounds, to: nil)) ?? .zero }

    func toast(_ text: String, undo: (() -> Void)? = nil) {
        self.undo = undo
        Toast.shared.show(text, action: undo.map { u in ("Undo", { [weak self] in self?.undo = nil; u() }) }, in: screenRect)
    }

    func focusList() { window?.makeFirstResponder(list.table) }

    func select(_ id: ListID) {
        current = id
        reload(keepSelection: false)
    }

    /// ⇥ / ⇧⇥ walk History → each pinboard → back around.
    func cycleList(back: Bool) {
        let ids = railButtons.map(\.0)
        guard let i = ids.firstIndex(of: current), !ids.isEmpty else { return }
        select(ids[(i + (back ? ids.count - 1 : 1)) % ids.count])
    }

    func resetForShow() {
        endEditing(commit: true)
        search.field.stringValue = ""
        query = ""
        filter = Filter()
        showTray(false)
        updateChips()
        reload(keepSelection: false)
        focusList()
    }

    func reload(keepSelection: Bool) {
        let boards = store.pinboards()
        if boards != pinboards || railButtons.isEmpty { pinboards = boards; buildRail() }
        var boardID: Int64?
        if case .board(let id) = current {
            if boards.contains(where: { $0.id == id }) { boardID = id } else { current = .history }
        }
        for (lid, b) in railButtons { b.selected = lid == current }

        let shown = store.search(query, filter: filter, board: boardID)
        filterButton.contentTintColor = filter.isEmpty ? .secondaryLabelColor : .controlAccentColor
        if !tray.isHidden { tray.update(filter, apps: store.topApps()) }
        let name = boardID.flatMap { id in boards.first { $0.id == id }?.name } ?? "History"
        titleLabel.stringValue = name
        countLabel.stringValue = "\(shown.count) clip\(shown.count == 1 ? "" : "s")"
        list.show(shown, grouped: boardID == nil, keepSelection: keepSelection, reorderable: boardID != nil && query.isEmpty && filter.isEmpty)
        empty.isHidden = !shown.isEmpty
        if !query.isEmpty || !filter.isEmpty {
            let what = query.trimmingCharacters(in: .whitespaces)
            empty.set(symbol: "magnifyingglass", title: "Nothing found",
                      subtitle: what.isEmpty ? "No clips match these filters." : "No clips match “\(what)”.")
        } else if boardID == nil {
            empty.set(symbol: "list.clipboard", title: "Nothing copied yet", subtitle: "Copy text, images, links or files and they'll show up here.")
        } else {
            empty.set(symbol: "pin", title: "\(name) is empty", subtitle: "Pin clips here from their card, or drag them onto this pinboard in the rail.")
        }
    }

    private func buildRail() {
        rail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        railButtons = [(.history, RailButton(symbol: "clock", tip: "History"))]
        for b in pinboards {
            let button = RailButton(board: b)
            button.menu = boardMenu(b)
            button.onDrop = { [weak self] ids in self?.pin(ids: ids, to: b) }
            railButtons.append((.board(b.id), button))
        }
        for (id, b) in railButtons {
            b.onClick = { [weak self] in self?.select(id) }
            rail.addArrangedSubview(b)
            if id == .history { rail.addArrangedSubview(RailDivider()) }
        }
        let add = RailButton(symbol: "plus", tip: "New Pinboard (⇧⌘N)", isAdd: true)
        add.onClick = { [weak self] in self?.newPinboard(pinning: []) }
        rail.addArrangedSubview(add)
    }

    // MARK: search + filters

    private func searchChanged(_ text: String) {
        let p = SearchTokens.peel(text, apps: store.topApps(limit: 50), boards: pinboards)
        if !p.kinds.isEmpty || !p.apps.isEmpty || p.board != nil {
            filter.kinds.formUnion(p.kinds)
            filter.apps.formUnion(p.apps)
            if let b = p.board { current = .board(b) }
            search.field.stringValue = p.text
            updateChips()
        }
        query = p.text
        reload(keepSelection: false)
    }

    private func setFilter(_ f: Filter) {
        filter = f
        updateChips()
        reload(keepSelection: false)
    }

    private func removeLastFilter() {
        if filter.date != nil { filter.date = nil } else if let a = filter.apps.sorted().last { filter.apps.remove(a) } else if let k = filter.kinds.max(by: { $0.rawValue < $1.rawValue }) { filter.kinds.remove(k) }
        setFilter(filter)
    }

    private func updateChips() {
        let apps = store.topApps(limit: 50)
        var chips: [(title: String, remove: () -> Void)] = []
        for k in filter.kinds.sorted(by: { $0.rawValue < $1.rawValue }) {
            chips.append((k.label, { [weak self] in guard let self else { return }; self.filter.kinds.remove(k); self.setFilter(self.filter) }))
        }
        for a in filter.apps.sorted() {
            chips.append((apps.first { $0.bundleID == a }?.name ?? a, { [weak self] in guard let self else { return }; self.filter.apps.remove(a); self.setFilter(self.filter) }))
        }
        if let d = filter.date {
            chips.append((d.label, { [weak self] in guard let self else { return }; self.filter.date = nil; self.setFilter(self.filter) }))
        }
        search.setChips(chips)
    }

    private func showTray(_ on: Bool) {
        tray.isHidden = !on
        listUnderSearch.isActive = !on
        listUnderTray.isActive = on
        if on { tray.update(filter, apps: store.topApps()) }
    }

    @objc private func filterClicked() { showTray(tray.isHidden) }
    @objc private func gearClicked() { onSettings() }

    // MARK: clip actions

    private func paste(plain: Bool) {
        let clips = list.selectedClips
        if !clips.isEmpty { onPaste(clips, plain) }
    }

    private func copy(_ clips: [Clip]) {
        guard !clips.isEmpty, PasteboardWriter.write(clips, plain: false, store: store) else { return }
        toast(clips.count == 1 ? "Copied" : "Copied \(clips.count) clips")
    }

    private func delete(_ clips: [Clip]) {
        guard !clips.isEmpty else { return }
        let ids = clips.map(\.id)
        store.delete(ids)
        reload(keepSelection: true)
        toast(clips.count == 1 ? "Deleted" : "Deleted \(clips.count) clips") { [weak self] in self?.store.restore(ids) }
    }

    private func pin(_ clips: [Clip], to board: Pinboard) { pin(ids: clips.map(\.id), to: board) }

    private func pin(ids: [Int64], to board: Pinboard) {
        guard !ids.isEmpty else { return }
        store.pin(ids, to: board.id)
        toast("Pinned to \(board.name)")
    }

    private func unpin(_ clips: [Clip]) {
        let pinned = clips.filter { $0.pinboard != nil }
        guard !pinned.isEmpty else { return }
        store.unpin(pinned.map(\.id))
        toast("Unpinned") { [weak self] in
            guard let self else { return }
            for c in pinned { if let b = c.pinboard { self.store.pin([c.id], to: b.id) } }
        }
    }

    private func performUndo() {
        guard let u = undo else { return NSSound.beep() }
        undo = nil
        u()
        toast("Undone")
    }

    private func cardAction(_ clip: Clip, _ action: CardView.Action, _ view: NSView) {
        switch action {
        case .copy: copy([clip])
        case .pin: pinMenu([clip]).popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        case .more: clipMenu([clip]).popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }
    }

    // MARK: menus

    private func clipMenu(_ clips: [Clip]) -> NSMenu {
        let m = NSMenu()
        m.addItem(ActionItem("Paste", key: "\r") { [weak self] in self?.onPaste(clips, false) })
        m.addItem(ActionItem("Paste as Plain Text", key: "\r", mods: .shift) { [weak self] in self?.onPaste(clips, true) })
        m.addItem(ActionItem("Copy", key: "c", mods: .command) { [weak self] in self?.copy(clips) })
        m.addItem(.separator())
        let pin = NSMenuItem(title: "Pin to", action: nil, keyEquivalent: "")
        pin.submenu = pinMenu(clips)
        m.addItem(pin)
        if clips.count == 1 { m.addItem(ActionItem("Rename…") { [weak self] in self?.beginRename(clips[0]) }) }
        m.addItem(.separator())
        m.addItem(ActionItem("Delete", key: "\u{8}", mods: []) { [weak self] in self?.delete(clips) })
        return m
    }

    private func pinMenu(_ clips: [Clip]) -> NSMenu {
        let m = NSMenu()
        for b in pinboards {
            let item = ActionItem(b.name) { [weak self] in self?.pin(clips, to: b) }
            item.image = Self.dot(b.color)
            item.state = clips.allSatisfy { $0.pinboard?.id == b.id } ? .on : .off
            m.addItem(item)
        }
        if !pinboards.isEmpty { m.addItem(.separator()) }
        m.addItem(ActionItem("New Pinboard…") { [weak self] in self?.newPinboard(pinning: clips) })
        if clips.contains(where: { $0.pinboard != nil }) { m.addItem(ActionItem("Unpin") { [weak self] in self?.unpin(clips) }) }
        return m
    }

    private func boardMenu(_ b: Pinboard) -> NSMenu {
        let m = NSMenu()
        m.addItem(ActionItem("Rename…") { [weak self] in self?.select(.board(b.id)); self?.beginRenameBoard(b) })
        let color = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        color.submenu = NSMenu()
        for rgb in Store.swatches {
            let item = ActionItem("") { [weak self] in self?.store.recolorPinboard(b.id, rgb: rgb); self?.reload(keepSelection: true) }
            item.image = Self.dot(NSColor(rgb: rgb), size: 14)
            item.state = rgb == b.rgb ? .on : .off
            color.submenu?.addItem(item)
        }
        m.addItem(color)
        m.addItem(ActionItem("Move Up") { [weak self] in self?.store.movePinboard(b.id, by: -1); self?.reload(keepSelection: true) })
        m.addItem(ActionItem("Move Down") { [weak self] in self?.store.movePinboard(b.id, by: 1); self?.reload(keepSelection: true) })
        m.addItem(.separator())
        m.addItem(ActionItem("Delete Pinboard") { [weak self] in
            guard let self else { return }
            self.store.deletePinboard(b.id)
            self.reload(keepSelection: false)
            self.toast("Deleted “\(b.name)”") { [weak self] in self?.store.restorePinboard(b.id) }
        })
        return m
    }

    @objc private func moreClicked() {
        let m: NSMenu
        if case .board(let id) = current, let b = pinboards.first(where: { $0.id == id }) { m = boardMenu(b) } else {
            m = NSMenu()
            m.addItem(ActionItem("New Pinboard", key: "n", mods: [.command, .shift]) { [weak self] in self?.newPinboard(pinning: []) })
            m.addItem(ActionItem("New Text Clip…", key: "n") { [weak self] in self?.onNewText() })
            m.addItem(.separator())
            m.addItem(ActionItem("Settings…", key: ",") { [weak self] in self?.onSettings() })
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height + 4), in: moreButton)
    }

    private static func dot(_ c: NSColor, size: CGFloat = 10) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            c.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }

    // MARK: pinboards + inline rename

    private func newPinboard(pinning clips: [Clip]) {
        let b = store.createPinboard()
        if !clips.isEmpty { store.pin(clips.map(\.id), to: b.id) }
        select(.board(b.id))
        beginRenameBoard(b)
    }

    private func beginRenameBoard(_ b: Pinboard) {
        let r = titleLabel.convert(titleLabel.bounds, to: self)
        let frame = NSRect(x: r.minX - 3, y: r.midY - 13, width: bounds.width - r.minX - 90, height: 26)
        beginEditing(frame: frame, text: b.name, placeholder: "Pinboard name", font: titleLabel.font!) { [weak self] name in
            guard let self, let name else { return }
            self.store.renamePinboard(b.id, to: name)
            self.reload(keepSelection: true)
        }
    }

    private func beginRename(_ c: Clip) {
        guard let row = list.row(of: c.id) else { return }
        list.table.scrollRowToVisible(row)
        let r = list.table.convert(list.table.rect(ofRow: row), to: self)
        let frame = NSRect(x: r.minX + 20, y: r.maxY - Theme.cardGap - CardView.bodyTop - 21, width: r.width - 40, height: 24)
        beginEditing(frame: frame, text: c.customTitle ?? "", placeholder: "Name this clip", font: CardView.titleFont) { [weak self] title in
            guard let self, let title else { return }
            self.store.rename(c.id, to: title)
            self.reload(keepSelection: true)
        }
    }

    private func beginEditing(frame: NSRect, text: String, placeholder: String, font: NSFont, done: @escaping (String?) -> Void) {
        endEditing(commit: true)
        let e = InlineEditor(frame: frame)
        e.stringValue = text
        e.placeholderString = placeholder
        e.font = font
        e.onDone = { [weak self, weak e] value in
            guard let self, let e, self.editor === e else { return }
            self.editor = nil
            e.removeFromSuperview()
            done(value)
            self.focusList()
        }
        addSubview(e)
        editor = e
        window?.makeFirstResponder(e)
        e.currentEditor()?.selectAll(nil)
    }

    private func endEditing(commit: Bool) { editor?.finish(commit: commit) }

    private static func makeGlass() -> NSView {
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = Theme.radius
            return g
        }
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = Theme.radius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }
}

/// Menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", mods: NSEvent.ModifierFlags = .command, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = mods
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// Text field laid over a card title or the pinboard name. ↩ or clicking away commits, Esc cancels.
final class InlineEditor: NSTextField, NSTextFieldDelegate {
    var onDone: (String?) -> Void = { _ in }
    private var finished = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBezeled = false
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        focusRingType = .exterior
        wantsLayer = true
        layer?.cornerRadius = 6
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        onDone(commit ? stringValue : nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)): finish(commit: true)
        case #selector(cancelOperation(_:)): finish(commit: false)
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) { finish(commit: true) }
}

/// Slightly darker strip behind the rail, rounded on the drawer's left corners only.
final class RailBackground: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Theme.radius
        layer?.cornerCurve = .continuous
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.railFill.cgColor }
}

final class RailDivider: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.hairline.cgColor }
}

/// A rail entry: History (symbol), a pinboard (colour tile with its initial, and a drop target for cards), or "+".
final class RailButton: NSView {
    var onClick: () -> Void = {}
    var onDrop: (([Int64]) -> Void)? { didSet { registerForDraggedTypes(onDrop == nil ? [] : [ClipList.clipType]) } }
    var selected = false { didSet { needsDisplay = true } }
    private var hover = false { didSet { needsDisplay = true } }

    init(symbol: String, tip: String, isAdd: Bool = false) {
        super.init(frame: .zero)
        setup(tip: tip)
        let i = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!)
        i.symbolConfiguration = .init(pointSize: isAdd ? 13 : 15, weight: .medium)
        i.contentTintColor = isAdd ? .tertiaryLabelColor : .labelColor
        center(i)
    }

    init(board: Pinboard) {
        super.init(frame: .zero)
        setup(tip: board.name)
        let tile = NSTextField(labelWithString: String(board.name.prefix(1)).uppercased())
        tile.font = .systemFont(ofSize: 12, weight: .bold)
        tile.textColor = .white
        tile.alignment = .center
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = board.color.cgColor
        box.layer?.cornerRadius = 7
        box.layer?.cornerCurve = .continuous
        tile.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(tile)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 22), box.heightAnchor.constraint(equalToConstant: 22),
            tile.centerXAnchor.constraint(equalTo: box.centerXAnchor), tile.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        center(box)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup(tip: String) {
        toolTip = tip
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        widthAnchor.constraint(equalToConstant: 36).isActive = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    private func center(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([v.centerXAnchor.constraint(equalTo: centerXAnchor), v.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseUp(with event: NSEvent) { onClick() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = selected || hover ? Theme.chipFill.cgColor : .clear
        layer?.borderWidth = hover && dragging ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    // Drag a card onto a pinboard tile to pin it.
    private var dragging = false
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragging = true; hover = true; return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { dragging = false; hover = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragging = false; hover = false
        let ids = ClipList.clipIDs(sender.draggingPasteboard)
        guard !ids.isEmpty else { return false }
        onDrop?(ids)
        return true
    }
}
