import AppKit

/// Pill at the top of the drawer ("Copied", "Pinned to Links", "Deleted · Undo"). Its own window, so it also shows after the drawer closes.
final class Toast {
    static let shared = Toast()

    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var action: (() -> Void)?
    private var generation = 0

    private init() {
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 17
        bg.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        button.isBordered = false
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.contentTintColor = .controlAccentColor
        button.target = self
        button.action = #selector(tapped)
        let stack = NSStackView(views: [label, button])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor), stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        panel.contentView = bg
    }

    /// `rect` is the drawer's frame on screen; the pill hangs just inside its top edge.
    func show(_ text: String, action: (String, () -> Void)? = nil, in rect: NSRect) {
        label.stringValue = text
        button.title = action?.0 ?? ""
        button.isHidden = action == nil
        self.action = action?.1
        panel.ignoresMouseEvents = action == nil
        let w = ceil(panel.contentView!.fittingSize.width), h: CGFloat = 34
        panel.setFrame(NSRect(x: rect.midX - w / 2, y: rect.maxY - h - 16, width: w, height: h), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }

        generation += 1
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 1.2 : 3.5)) { [weak self] in
            guard let self, self.generation == g else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self.panel.animator().alphaValue = 0 }) {
                if self.generation == g { self.panel.orderOut(nil) }
            }
        }
    }

    @objc private func tapped() {
        action?()
        action = nil
        generation += 1
        panel.orderOut(nil)
    }
}
