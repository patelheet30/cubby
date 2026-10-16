import AppKit

/// Vertical list of content-sized cards, grouped by day in History.
final class ClipList: NSScrollView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Row { case day(String), clip(Clip, index: Int) }
    static let clipType = NSPasteboard.PasteboardType("com.heetpatel.cubby.clip-id")

    let table = ClipTable()
    private(set) var rows: [Row] = []
    private(set) var clips: [Clip] = []
    private var hoverRow = -1
    private var showsPinTags = true
    private var reorderable = false
    var menuProvider: ([Clip]) -> NSMenu = { _ in NSMenu() }
    var onCardAction: (Clip, CardView.Action, NSView) -> Void = { _, _, _ in }
    var onReorder: ([Int64]) -> Void = { _ in }
    var onSelectionChange: () -> Void = {}
    /// Clip ids shown last time, so a capture arriving while open can slide its card in.
    private var shownIDs: [Int64] = []

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 10, right: 0)
        let col = NSTableColumn(identifier: .init("c"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.allowsTypeSelect = false
        table.allowsMultipleSelection = true
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        documentView = table
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.registerForDraggedTypes([Self.clipType])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                             owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `grouped` adds day headers (History); pinboards are one flat list.
    func show(_ clips: [Clip], grouped: Bool, keepSelection: Bool = false, reorderable: Bool = false) {
        let keep = keepSelection ? Set(selectedClips.map(\.id)) : []
        self.clips = clips
        self.reorderable = reorderable
        showsPinTags = grouped
        rows = []
        var lastDay = ""
        for (i, c) in clips.enumerated() {
            if grouped {
                let day = Theme.dayTitle(c.date)
                if day != lastDay { rows.append(.day(day)); lastDay = day }
            }
            rows.append(.clip(c, index: i))
        }
        let newTop = clips.first.map(\.id)
        let isLiveInsert = keepSelection && newTop != nil && !shownIDs.contains(newTop!) && !shownIDs.isEmpty
        shownIDs = clips.map(\.id)
        table.reloadData()
        if isLiveInsert, let r = row(of: newTop!), let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false) {
            cell.wantsLayer = true
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
            let drop = CASpringAnimation(keyPath: "transform.translation.y"); drop.fromValue = -16; drop.toValue = 0
            drop.stiffness = 400; drop.damping = 30
            for a in [fade, drop] as [CABasicAnimation] { a.duration = 0.35; cell.layer?.add(a, forKey: a.keyPath) }
        }
        let kept = IndexSet(rows.indices.filter { if case .clip(let c, _) = rows[$0] { keep.contains(c.id) } else { false } })
        if !kept.isEmpty {
            table.selectRowIndexes(kept, byExtendingSelection: false)
        } else if let first = rows.firstIndex(where: { if case .clip = $0 { true } else { false } }) {
            table.selectRowIndexes([first], byExtendingSelection: false)
            if !keepSelection { table.scrollRowToVisible(0) }
        }
    }

    func row(of id: Int64) -> Int? { rows.firstIndex { if case .clip(let c, _) = $0 { c.id == id } else { false } } }

    private func clip(at row: Int) -> Clip? {
        guard rows.indices.contains(row), case .clip(let c, _) = rows[row] else { return nil }
        return c
    }

    @objc private func doubleClicked() {
        if clip(at: table.clickedRow) != nil { table.onActivate(false) }
    }

    // Right-click: act on the selection if the clicked card is in it, otherwise on just that card.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let r = table.clickedRow
        guard clip(at: r) != nil else { return }
        if !table.selectedRowIndexes.contains(r) { table.selectRowIndexes([r], byExtendingSelection: false) }
        for item in menuProvider(selectedClips).items { item.menu?.removeItem(item); menu.addItem(item) }
    }

    // MARK: drag out, drag onto a pinboard tile, reorder inside a pinboard

    static func clipIDs(_ pb: NSPasteboard) -> [Int64] {
        (pb.pasteboardItems ?? []).compactMap { $0.string(forType: clipType).flatMap { Int64($0) } }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let c = clip(at: row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(c.id), forType: Self.clipType)
        for it in Store.shared.payload(c.id)?.prefix(1) ?? [] {
            for t in it.types where t != Self.clipType.rawValue { if let d = it.data[t] { item.setData(d, forType: .init(t)) } }
        }
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard reorderable, info.draggingSource as? NSTableView === table else { return [] }
        if op == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let moving = Self.clipIDs(info.draggingPasteboard)
        guard reorderable, !moving.isEmpty else { return false }
        let before = clips.prefix(min(row, clips.count)).filter { !moving.contains($0.id) }.map(\.id)
        let after = clips.dropFirst(min(row, clips.count)).filter { !moving.contains($0.id) }.map(\.id)
        onReorder(before + moving + after)
        return true
    }

    var selectedClips: [Clip] {
        table.selectedRowIndexes.compactMap { if case .clip(let c, _) = rows[$0] { c } else { nil } }
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .day: 30
        case .clip(let c, _): CardView.height(for: c, width: cardWidth) + Theme.cardGap
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .clip = rows[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .day(let title):
            let v = tableView.makeView(withIdentifier: .init("day"), owner: nil) as? DayHeader ?? DayHeader()
            v.identifier = .init("day")
            v.label.stringValue = title
            return v
        case .clip(let c, let i):
            let v = tableView.makeView(withIdentifier: .init("card"), owner: nil) as? CardCell ?? CardCell()
            v.identifier = .init("card")
            v.card.configure(c, quickKey: i < 9 ? i + 1 : nil, pinTag: showsPinTags)
            v.card.onAction = { [weak self] action, view in self?.onCardAction(c, action, view) }
            v.card.isSelected = tableView.isRowSelected(row)
            v.card.isHovered = row == hoverRow
            return v
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refreshStates(); onSelectionChange() }

    /// Screen rect of a clip's card (for the preview's arrow).
    func screenRect(of id: Int64) -> NSRect? {
        guard let r = row(of: id), let w = window else { return nil }
        var rect = table.rect(ofRow: r).insetBy(dx: 12, dy: 0)
        rect.origin.y += Theme.cardGap; rect.size.height -= Theme.cardGap
        let visible = table.convert(rect, to: nil).intersection(convert(bounds, to: nil))
        return w.convertToScreen(visible.isEmpty ? table.convert(rect, to: nil) : visible)
    }

    private var cardWidth: CGFloat { max(200, contentSize.width - 24) }

    private func refreshStates() {
        let visible = table.rows(in: table.visibleRect)
        for r in visible.lowerBound..<visible.upperBound {
            guard let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? CardCell else { continue }
            cell.card.isSelected = table.isRowSelected(r)
            cell.card.isHovered = r == hoverRow
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let r = table.row(at: table.convert(event.locationInWindow, from: nil))
        if r != hoverRow { hoverRow = r; refreshStates() }
    }

    override func mouseExited(with event: NSEvent) { hoverRow = -1; refreshStates() }
}

/// Table that hands printable keys to search and Esc to the drawer, but keeps arrows for itself.
final class ClipTable: NSTableView {
    var onType: (String) -> Void = { _ in }
    var onEscape: () -> Void = {}
    var onTab: (Bool) -> Void = { _ in }
    var onActivate: (Bool) -> Void = { _ in }       // ↩ / ⇧↩
    var onQuick: (Int, Bool) -> Void = { _, _ in }   // ⌘1–9 (⇧ = plain)
    var onCopy: () -> Void = {}
    var onDelete: () -> Void = {}
    var onUndo: () -> Void = {}
    var onNewPinboard: () -> Void = {}
    var onFind: () -> Void = {}
    var onPreview: () -> Void = {}
    var onNewText: () -> Void = {}

    private static let digitKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25] // 1…9

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        let shift = event.modifierFlags.contains(.shift)
        switch (event.keyCode, mods) {
        case (53, _): return onEscape()
        case (48, []): return onTab(shift)
        case (36, []), (76, []): return onActivate(shift)
        case (51, []), (117, []), (51, .command): return onDelete()
        case (123, .command), (124, .command): return onTab(event.keyCode == 123)
        case (45, .command) where shift: return onNewPinboard()
        case (3, .command): return onFind()
        case (49, []): return onPreview()
        case (45, .command) where !shift: return onNewText()
        default: break
        }
        if mods == .command, let n = Self.digitKeys.firstIndex(of: event.keyCode) { return onQuick(n + 1, shift) }
        if mods.isEmpty, let chars = event.characters, DrawerPanel.isPrintable(chars), chars != " " { return onType(chars) }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { onCopy() }
    @objc func delete(_ sender: Any?) { onDelete() }
    @objc func undo(_ sender: Any?) { onUndo() }
}

final class DayHeader: NSView {
    let label = NSTextField(labelWithString: "")
    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Row container: the card inset 12 pt from the list edges, gap below.
final class CardCell: NSView {
    let card = CardView()
    init() {
        super.init(frame: .zero)
        addSubview(card)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        card.frame = CGRect(x: 12, y: Theme.cardGap, width: bounds.width - 24, height: bounds.height - Theme.cardGap)
    }
    override var isFlipped: Bool { true }
}

/// One clip. Frames are computed by hand so `height(for:width:)` and layout always agree.
final class CardView: NSView {
    enum Action: Int { case pin, copy, more }
    var onAction: (Action, NSView) -> Void = { _, _ in }
    static let pad: CGFloat = 12
    static let headerH: CGFloat = 18
    static let bodyTop: CGFloat = pad + headerH + 8
    static let textFont = NSFont.systemFont(ofSize: 13)
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let maxTextLines = 4

    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true; actions.isHidden = !isHovered; quick.isHidden = isHovered || quickKey == nil } } }

    private var clip: Clip?
    private var quickKey: Int?
    private var showsTag = true
    private let appIcon = NSImageView()
    private let source = NSTextField(labelWithString: "")
    private let pinTag = PinTag()
    private let quick = KeyCap("")
    private let actions = NSStackView()
    private let title = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let media = MediaView()
    private let metric = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Theme.cardRadius
        layer?.cornerCurve = .continuous
        source.font = .systemFont(ofSize: 11, weight: .medium)
        source.textColor = .secondaryLabelColor
        source.lineBreakMode = .byTruncatingTail
        title.font = Self.titleFont
        title.lineBreakMode = .byTruncatingTail
        body.font = Self.textFont
        body.maximumNumberOfLines = Self.maxTextLines
        body.lineBreakMode = .byWordWrapping
        body.cell?.truncatesLastVisibleLine = true
        metric.font = .systemFont(ofSize: 11)
        metric.textColor = .tertiaryLabelColor
        metric.lineBreakMode = .byTruncatingHead
        for (i, (symbol, tip)) in [("pin", "Pin"), ("doc.on.doc", "Copy"), ("ellipsis", "More")].enumerated() {
            let b = IconButton(symbol: symbol, tip: tip, size: 22)
            b.tag = i
            b.target = self
            b.action = #selector(actionTapped(_:))
            actions.addArrangedSubview(b)
        }
        actions.spacing = 2
        actions.isHidden = true
        for v in [appIcon, source, pinTag, quick, actions, title, body, media, metric] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    @objc private func actionTapped(_ b: NSButton) { onAction(Action(rawValue: b.tag)!, b) }

    func configure(_ c: Clip, quickKey: Int?, pinTag showTag: Bool = true) {
        clip = c
        showsTag = showTag
        self.quickKey = quickKey
        appIcon.image = c.appIcon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        source.stringValue = "\(c.appName) · \(Theme.shortTime(c.date))"
        pinTag.set(c.pinboard)
        quick.set(quickKey.map { "⌘\($0)" } ?? "")
        quick.isHidden = quickKey == nil || isHovered
        title.stringValue = c.title ?? ""
        body.stringValue = ""
        media.clear()
        switch c.kind {
        case .text: body.stringValue = c.text ?? ""
        case .image: media.showImage(c.image)
        case .link: media.showLink(image: c.image)
            title.stringValue = c.title ?? (c.text ?? "")
            body.stringValue = c.text.flatMap { URL(string: $0)?.host() } ?? ""
        case .color: media.showColor(c.color, hex: c.text ?? "")
        case .file: media.showFile(c.image)
            title.stringValue = (c.paths.first as NSString?)?.lastPathComponent ?? "File"
        case .unknown: body.stringValue = "Preview unavailable — the content is saved and can be pasted."
        }
        body.textColor = c.kind == .link ? .secondaryLabelColor : .labelColor
        body.font = c.kind == .link ? .systemFont(ofSize: 12) : Self.textFont
        body.maximumNumberOfLines = c.kind == .link ? 1 : Self.maxTextLines
        metric.stringValue = c.kind == .link || c.kind == .color ? "" : c.metric
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let c = clip else { return }
        let p = Self.pad, w = bounds.width - 2 * p
        appIcon.frame = CGRect(x: p, y: p + 1, width: 16, height: 16)
        let qs = quick.fittingSize
        quick.frame = CGRect(x: bounds.width - p - qs.width, y: p, width: qs.width, height: 17)
        actions.frame = CGRect(x: bounds.width - p - 70, y: p - 3, width: 70, height: 22)
        let ts = pinTag.fittingSize
        let tagRight = bounds.width - p - (quickKey == nil ? 0 : qs.width + 6)
        pinTag.frame = CGRect(x: tagRight - ts.width, y: p, width: ts.width, height: 17)
        pinTag.isHidden = c.pinboard == nil || !showsTag
        source.frame = CGRect(x: p + 22, y: p + 1, width: max(0, (pinTag.isHidden ? tagRight : pinTag.frame.minX) - p - 30), height: 16)

        var y = Self.bodyTop
        let titleH = Self.titleHeight(c)
        switch c.kind {
        case .text, .unknown:
            title.frame = CGRect(x: p, y: y, width: w, height: titleH)
            y += titleH
            let h = Self.textHeight(c, width: w)
            body.frame = CGRect(x: p, y: y, width: w, height: h)
            y += h
            media.frame = .zero
        case .image:
            let h = Self.mediaHeight(c, width: w)
            media.frame = CGRect(x: p, y: y, width: w, height: h)
            y += h
            title.frame = .zero; body.frame = .zero
        case .link, .file:
            media.frame = CGRect(x: p, y: y, width: 48, height: 48)
            title.frame = CGRect(x: p + 60, y: y + 6, width: w - 60, height: 17)
            body.frame = CGRect(x: p + 60, y: y + 25, width: w - 60, height: 16)
            y += 48
            if c.kind == .file { body.frame = .zero }
        case .color:
            let h = Self.mediaHeight(c, width: w)
            media.frame = CGRect(x: p, y: y, width: w, height: h)
            y += h
            title.frame = .zero; body.frame = .zero
        }
        if c.kind == .file {
            metric.frame = CGRect(x: p + 60, y: Self.bodyTop + 25, width: w - 60, height: 15)
        } else {
            metric.frame = metric.stringValue.isEmpty ? .zero : CGRect(x: p, y: y + 6, width: w, height: 15)
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (isHovered || isSelected ? Theme.cardHover : Theme.cardFill).cgColor
        layer?.borderWidth = isSelected ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    // MARK: sizing (shared by layout and the table's row heights)

    static func titleHeight(_ c: Clip) -> CGFloat { (c.kind == .text || c.kind == .unknown) && c.title != nil ? 20 : 0 }

    static func textHeight(_ c: Clip, width: CGFloat) -> CGFloat {
        let text = c.kind == .unknown ? "Preview unavailable — the content is saved and can be pasted." : (c.text ?? "")
        let line = ceil(textFont.ascender - textFont.descender + textFont.leading) + 1
        let r = (text as NSString).boundingRect(with: CGSize(width: width - 4, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: textFont])
        return min(ceil(r.height) + 2, line * CGFloat(maxTextLines) + 2)
    }

    static func mediaHeight(_ c: Clip, width: CGFloat) -> CGFloat {
        switch c.kind {
        case .image:
            guard let s = c.pixelSize ?? c.image?.size, s.width > 0 else { return 120 }
            return min(max(width * s.height / s.width, 60), 260)
        case .color: return 44
        default: return 48
        }
    }

    static func height(for c: Clip, width: CGFloat) -> CGFloat {
        let w = width - 2 * pad
        var h = bodyTop
        switch c.kind {
        case .text, .unknown: h += titleHeight(c) + textHeight(c, width: w)
        case .image, .color: h += mediaHeight(c, width: w)
        case .link, .file: h += 48
        }
        let hasMetric = c.kind == .text || c.kind == .image
        return h + (hasMetric ? 21 : 0) + pad
    }
}

/// Image / link thumbnail / file icon / colour swatch inside a card.
final class MediaView: NSView {
    private let image = NSImageView()
    private let hex = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        hex.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        hex.alignment = .center
        addSubview(image)
        addSubview(hex)
    }

    required init?(coder: NSCoder) { fatalError() }

    func clear() {
        layer?.contents = nil
        image.image = nil
        hex.stringValue = ""
        layer?.backgroundColor = nil
        image.imageScaling = .scaleProportionallyUpOrDown
    }

    /// The whole picture, never cropped: the box has the photo's aspect (capped in height), and anything taller is letterboxed.
    func showImage(_ img: NSImage?) {
        layer?.contents = img
        layer?.contentsGravity = .resizeAspect
        layer?.minificationFilter = .trilinear
        layer?.backgroundColor = Theme.fieldFill.cgColor
    }

    func showLink(image img: NSImage?) {
        image.image = img ?? NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        image.contentTintColor = .tertiaryLabelColor
        layer?.backgroundColor = Theme.fieldFill.cgColor
    }

    func showFile(_ img: NSImage?) { image.image = img ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil) }

    func showColor(_ c: NSColor?, hex text: String) {
        layer?.backgroundColor = c?.cgColor
        hex.stringValue = text
        let lum = c.flatMap { $0.usingColorSpace(.sRGB) }.map { 0.299 * $0.redComponent + 0.587 * $0.greenComponent + 0.114 * $0.blueComponent } ?? 0
        hex.textColor = lum > 0.6 ? .black : .white
    }

    override func layout() {
        super.layout()
        image.frame = bounds.insetBy(dx: bounds.height < 60 ? 6 : 0, dy: bounds.height < 60 ? 6 : 0)
        hex.frame = CGRect(x: 0, y: (bounds.height - 18) / 2, width: bounds.width, height: 18)
    }
}

/// "● Links" capsule shown on cards that are pinned.
final class PinTag: NSView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8.5
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7), dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ board: Pinboard?) {
        label.stringValue = board?.name ?? ""
        dot.layer?.backgroundColor = board?.color.cgColor
        layer?.backgroundColor = board?.color.withAlphaComponent(0.18).cgColor
    }
}
