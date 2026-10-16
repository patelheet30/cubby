import AppKit

extension ItemKind {
    var symbol: String {
        switch self {
        case .unknown: "questionmark.square.dashed"
        case .image: "photo"
        case .color: "paintpalette"
        case .file: "doc"
        case .link: "link"
        case .text: "text.alignleft"
        }
    }
}

/// Turns finished words in the search text into filters: "mail link meeting" → app Mail, kind Link, text "meeting".
enum SearchTokens {
    struct Peeled: Equatable {
        var text: String
        var kinds: Set<ItemKind> = []
        var apps: Set<String> = []
        var board: Int64? = nil
    }

    /// Only words followed by a space count as finished, so typing "lin" never jumps to a chip early.
    static func peel(_ text: String, apps: [(bundleID: String, name: String)], boards: [Pinboard]) -> Peeled {
        var out = Peeled(text: "")
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let unfinished = words.removeLast()
        var kept: [String] = []
        for w in words where !w.isEmpty {
            let l = w.lowercased()
            if let k = ItemKind.allCases.first(where: { [$0.label.lowercased(), $0.label.lowercased() + "s"].contains(l) }), k != .unknown {
                out.kinds.insert(k)
            } else if let a = apps.first(where: { $0.name.lowercased() == l || ($0.name.split(separator: " ").first?.lowercased() == l && l.count >= 3) }) {
                out.apps.insert(a.bundleID)
            } else if let b = boards.first(where: { $0.name.lowercased() == l }) {
                out.board = b.id
            } else {
                kept.append(w)
            }
        }
        out.text = (kept + [unfinished]).joined(separator: " ")
        return out
    }
}

/// Fold-out filter grid under the search field: Type, App, Date. Three chips per row.
final class FilterTray: NSStackView {
    var onChange: (Filter) -> Void = { _ in }
    private var filter = Filter()

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 6, right: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ f: Filter, apps: [(bundleID: String, name: String)]) {
        filter = f
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        section("Type", ItemKind.allCases.filter { $0 != .unknown }.map { k in
            Chip(k.label, symbol: k.symbol, on: f.kinds.contains(k)) { [weak self] in self?.toggle { $0.kinds.formSymmetricDifference([k]) } }
        })
        if !apps.isEmpty {
            section("App", apps.map { a in
                let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: a.bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
                return Chip(a.name, image: icon, on: f.apps.contains(a.bundleID)) { [weak self] in
                    self?.toggle { $0.apps.formSymmetricDifference([a.bundleID]) }
                }
            })
        }
        section("Date", DateFilter.allCases.map { d in
            Chip(d.label, symbol: "calendar", on: f.date == d) { [weak self] in self?.toggle { $0.date = $0.date == d ? nil : d } }
        })
    }

    private func toggle(_ change: (inout Filter) -> Void) {
        change(&filter)
        onChange(filter)
    }

    private func section(_ title: String, _ chips: [Chip]) {
        let l = NSTextField(labelWithString: title.uppercased())
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .tertiaryLabelColor
        addArrangedSubview(l)
        for start in stride(from: 0, to: chips.count, by: 3) {
            var row = Array(chips[start..<min(start + 3, chips.count)]) as [NSView]
            while row.count < 3 { row.append(NSView()) }
            let r = NSStackView(views: row)
            r.distribution = .fillEqually
            r.spacing = 6
            addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }
}

/// Toggle chip: icon + label, accent-tinted when on.
final class Chip: NSView {
    private let action: () -> Void
    private let on: Bool
    private var hover = false { didSet { needsDisplay = true } }

    init(_ title: String, symbol: String? = nil, image: NSImage? = nil, on: Bool, action: @escaping () -> Void) {
        self.action = action
        self.on = on
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        let icon = NSImageView(image: image ?? symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) } ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        icon.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11.5, weight: on ? .semibold : .regular)
        label.textColor = on ? .controlAccentColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let s = NSStackView(views: [icon, label])
        s.spacing = 5
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            s.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            s.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseUp(with event: NSEvent) { action() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (on ? NSColor.controlAccentColor.withAlphaComponent(0.16) : hover ? Theme.chipFill : Theme.fieldFill).cgColor
    }
}
