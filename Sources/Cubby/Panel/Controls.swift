import AppKit

/// Always-visible search capsule (full width of the drawer column).
final class SearchField: NSView, NSTextFieldDelegate {
    let field = FocusField()
    var onEscapeWhenEmpty: () -> Void = {}
    var onChange: (String) -> Void = { _ in }
    var onMoveDown: () -> Void = {}
    var onBackspaceEmpty: () -> Void = {}
    private let chips = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.cornerCurve = .continuous
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        field.placeholderString = "Search clips"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.onFocus = { [weak self] in self?.setFocused(true) }
        chips.spacing = 4
        let stack = NSStackView(views: [icon, chips, field])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { layer?.backgroundColor = Theme.fieldFill.cgColor }
    override var wantsUpdateLayer: Bool { true }

    func setFocused(_ on: Bool) {
        layer?.borderWidth = on ? 1.5 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
    }

    func controlTextDidEndEditing(_ obj: Notification) { setFocused(false) }
    func controlTextDidChange(_ obj: Notification) { onChange(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(cancelOperation(_:)):
            if field.stringValue.isEmpty { onEscapeWhenEmpty() } else { field.stringValue = ""; onChange("") }
        case #selector(moveDown(_:)), #selector(insertNewline(_:)): onMoveDown()
        case #selector(deleteBackward(_:)) where field.stringValue.isEmpty && !chips.arrangedSubviews.isEmpty: onBackspaceEmpty()
        default: return false
        }
        return true
    }

    /// Active filters, shown as small removable capsules before the text.
    func setChips(_ items: [(title: String, remove: () -> Void)]) {
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            let b = FirstMouseButton(title: item.title + "  ×", target: nil, action: nil)
            b.isBordered = false
            b.font = .systemFont(ofSize: 11, weight: .semibold)
            b.contentTintColor = .controlAccentColor
            b.wantsLayer = true
            b.layer?.cornerRadius = 9
            b.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            b.heightAnchor.constraint(equalToConstant: 18).isActive = true
            b.widthAnchor.constraint(equalToConstant: b.fittingSize.width + 10).isActive = true
            let remove = item.remove
            b.target = ClosureTarget.make(b) { remove() }
            b.action = #selector(ClosureTarget.fire)
            chips.addArrangedSubview(b)
        }
        field.placeholderString = items.isEmpty ? "Search clips" : "Search"
    }

    /// Puts `text` in the field and focuses it (typing anywhere in the drawer starts a search).
    func begin(with text: String) {
        window?.makeFirstResponder(field)
        field.currentEditor()?.insertText(text) // fires controlTextDidChange
    }
}

/// Retains a closure as a target/action pair for the control it's attached to.
final class ClosureTarget: NSObject {
    private let f: () -> Void
    private static var key = 0
    init(_ f: @escaping () -> Void) { self.f = f }
    static func make(_ owner: NSObject, _ f: @escaping () -> Void) -> ClosureTarget {
        let t = ClosureTarget(f)
        objc_setAssociatedObject(owner, &key, t, .OBJC_ASSOCIATION_RETAIN)
        return t
    }
    @objc func fire() { f() }
}

final class FocusField: NSTextField {
    var onFocus: () -> Void = {}
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus() }
        return ok
    }
}

/// Borderless SF Symbol button with a hover fill.
final class IconButton: NSButton {
    private var hover = false { didSet { needsDisplay = true } }

    init(symbol: String, tip: String, size: CGFloat = 28) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        symbolConfiguration = .init(pointSize: size > 24 ? 13 : 11, weight: .medium)
        contentTintColor = .secondaryLabelColor
        isBordered = false
        toolTip = tip
        wantsLayer = true
        layer?.cornerRadius = size > 24 ? 8 : 6
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = hover ? Theme.chipFill.cgColor : .clear }
}

/// Keycap hints for the current context, plus a trailing status label.
final class HintBar: NSStackView {
    private let trailingLabel = NSTextField(labelWithString: "")

    func set(keys: [(String, String)], trailing: String) {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        orientation = .horizontal
        spacing = 12
        for (key, label) in keys {
            let pair = NSStackView(views: [KeyCap(key), Self.label(label)])
            pair.spacing = 4
            addArrangedSubview(pair)
        }
        guard !trailing.isEmpty else { return }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        addArrangedSubview(spacer)
        trailingLabel.stringValue = trailing
        trailingLabel.font = .systemFont(ofSize: 11)
        trailingLabel.textColor = .tertiaryLabelColor
        addArrangedSubview(trailingLabel)
    }

    private static func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }
}

/// A small rounded keycap ("⌘1", "↩", "Esc").
final class KeyCap: NSView {
    private let label = NSTextField(labelWithString: "")

    func set(_ key: String) { label.stringValue = key; invalidateIntrinsicContentSize() }

    init(_ key: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        label.stringValue = key
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 17),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 19),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.borderColor = Theme.hairline.cgColor }
}

/// Centred icon + title + subtitle, used for empty history, empty pinboards and no search results.
final class EmptyState: NSStackView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let sub = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.symbolConfiguration = .init(pointSize: 26, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .center
        sub.preferredMaxLayoutWidth = 240
        orientation = .vertical
        spacing = 6
        for v in [icon, title, sub] { addArrangedSubview(v) }
        setCustomSpacing(10, after: icon)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(symbol: String, title t: String, subtitle: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        title.stringValue = t
        sub.stringValue = subtitle
    }
}
