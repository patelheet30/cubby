import AppKit
import Quartz
import WebKit

/// Space-bar preview: a popover-style panel to the left of the drawer, its arrow pointing at the selected card.
/// Never takes key, so the drawer keeps the keyboard and ↑↓ keep moving the selection (the preview follows).
final class PreviewPanel {
    static let arrow: CGFloat = 9

    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let bg = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let footerButton = FirstMouseButton(title: "", target: nil, action: nil)
    private var body: NSView?
    private let reveal = FirstMouseButton(title: "Reveal Secret", target: nil, action: nil)
    private var footerAction: (() -> Void)?
    private(set) var clipID: Int64?
    var store = Store.shared

    var isVisible: Bool { panel.isVisible }

    init() {
        panel.level = .mainMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingMiddle
        footerButton.bezelStyle = .push
        footerButton.controlSize = .small
        footerButton.target = self
        footerButton.action = #selector(footerTapped)
        reveal.bezelStyle = .push
        reveal.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        reveal.imagePosition = .imageLeading
        reveal.target = self
        reveal.action = #selector(revealTapped)
        for v in [titleLabel, footerLabel, footerButton] { bg.addSubview(v) }
        panel.contentView = bg
    }

    func hide() {
        clipID = nil
        panel.orderOut(nil)
        body?.removeFromSuperview()
        body = nil // stops web views / Quick Look
    }

    /// `card` and `drawer` are screen rects.
    func show(_ clip: Clip, card: NSRect, drawer: NSRect, sharing: NSWindow.SharingType) {
        panel.sharingType = sharing
        if clipID != clip.id { build(clip) }
        clipID = clip.id
        place(card: card, drawer: drawer)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
    }

    private var contentSize = CGSize(width: 480, height: 300)

    private func build(_ c: Clip) {
        body?.removeFromSuperview()
        let payload = store.payload(c.id)
        titleLabel.stringValue = c.title ?? "\(c.kind.label) from \(c.appName)"
        footerAction = nil
        var footer = c.metric
        var button: (String, () -> Void)?
        let v: NSView
        switch c.kind {
        case .text:
            let s = payload.flatMap(Classifier.string) ?? c.text ?? ""
            let tv = NSTextView()
            tv.string = s
            tv.isEditable = false
            tv.font = .systemFont(ofSize: 13)
            tv.textContainerInset = NSSize(width: 6, height: 6)
            tv.drawsBackground = false
            let sv = NSScrollView()
            sv.documentView = tv
            sv.hasVerticalScroller = true
            sv.drawsBackground = false
            tv.autoresizingMask = .width
            let w: CGFloat = 480
            let h = (s as NSString).boundingRect(with: CGSize(width: w - 24, height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin], attributes: [.font: NSFont.systemFont(ofSize: 13)]).height
            contentSize = CGSize(width: w, height: min(max(ceil(h) + 20, 60), 560))
            let p = c.preview
            func n(_ v: Int, _ unit: String) -> String { "\(v.formatted()) \(unit)\(v == 1 ? "" : "s")" }
            footer = [n(p.textLength ?? s.count, "character"), n(p.words ?? 0, "word"), n(p.lines ?? 0, "line")].joined(separator: " · ")
            v = sv
        case .image:
            let img = payload.flatMap(Classifier.imageData).flatMap(NSImage.init(data:))
                ?? c.paths.first.flatMap(NSImage.init(contentsOfFile:)) ?? c.image
            let iv = NSImageView(image: img ?? NSImage())
            iv.imageScaling = .scaleProportionallyUpOrDown
            let px = c.pixelSize ?? img?.size ?? CGSize(width: 400, height: 300)
            let scale = min(1, 560 / max(px.width, 1), 600 / max(px.height, 1))
            contentSize = CGSize(width: max(240, px.width * scale), height: max(160, px.height * scale))
            v = iv
        case .link:
            let web = WKWebView()
            if let s = c.text, let url = URL(string: s) {
                web.load(URLRequest(url: url))
                button = ("Open in Browser", { NSWorkspace.shared.open(url) })
            }
            footer = c.text ?? ""
            contentSize = CGSize(width: 640, height: 460)
            v = web
        case .file:
            let path = c.paths.first ?? ""
            if FileManager.default.fileExists(atPath: path), let ql = QLPreviewView(frame: .zero, style: .compact) {
                ql.previewItem = URL(fileURLWithPath: path) as NSURL
                v = ql
            } else {
                let iv = NSImageView(image: c.image ?? NSImage())
                iv.imageScaling = .scaleProportionallyUpOrDown
                v = iv
                footer = "Missing: " + path
            }
            if c.paths.count == 1 { footer = path }
            button = ("Reveal in Finder", { NSWorkspace.shared.activateFileViewerSelecting(c.paths.map { URL(fileURLWithPath: $0) }) })
            contentSize = CGSize(width: 520, height: 440)
        case .color:
            let sw = NSView()
            sw.wantsLayer = true
            sw.layer?.backgroundColor = c.color?.cgColor
            sw.layer?.cornerRadius = 10
            if let rgb = c.color?.usingColorSpace(.sRGB) {
                footer = "\(c.text ?? "") · rgb(\(Int(rgb.redComponent * 255)), \(Int(rgb.greenComponent * 255)), \(Int(rgb.blueComponent * 255)))"
            }
            contentSize = CGSize(width: 280, height: 200)
            v = sw
        case .unknown:
            let l = NSTextField(wrappingLabelWithString: "Stored types:\n" + (c.preview.types ?? []).joined(separator: "\n"))
            l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            contentSize = CGSize(width: 380, height: 200)
            v = l
        }
        reveal.removeFromSuperview()
        if c.sensitive { // blurred until asked
            v.wantsLayer = true
            v.layerUsesCoreImageFilters = true
            v.layer?.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 9])!]
        }
        footerLabel.stringValue = footer
        footerButton.title = button?.0 ?? ""
        footerButton.isHidden = button == nil
        footerAction = button?.1
        bg.addSubview(v)
        body = v
        if c.sensitive { bg.addSubview(reveal) }
    }

    private func place(card: NSRect, drawer: NSRect) {
        let header: CGFloat = 34, footer: CGFloat = 34, pad: CGFloat = 10, a = Self.arrow
        let w = contentSize.width + 2 * pad + a, h = contentSize.height + header + footer
        let screen = NSScreen.screens.first { $0.frame.intersects(drawer) }?.visibleFrame ?? drawer
        var f = NSRect(x: drawer.minX - w - 2, y: card.midY - h / 2, width: w, height: h)
        f.origin.y = min(max(f.minY, screen.minY + 10), screen.maxY - h - 10)
        f.origin.x = max(f.minX, screen.minX + 10)
        let arrowY = min(max(card.midY - f.minY, 26), h - 26)
        panel.setFrame(f, display: false)
        bg.frame = NSRect(origin: .zero, size: f.size)
        bg.maskImage = Self.mask(size: f.size, arrowY: arrowY)
        let cw = w - a
        titleLabel.frame = NSRect(x: pad + 2, y: h - header + 8, width: cw - 2 * pad - 4, height: 18)
        body?.frame = NSRect(x: pad, y: footer, width: contentSize.width, height: contentSize.height)
        let rs = reveal.fittingSize
        reveal.frame = NSRect(x: pad + (contentSize.width - rs.width) / 2, y: footer + (contentSize.height - rs.height) / 2,
                              width: rs.width, height: rs.height)
        let bw = footerButton.isHidden ? 0 : footerButton.fittingSize.width
        footerButton.frame = NSRect(x: cw - pad - bw, y: 6, width: bw, height: 22)
        footerLabel.frame = NSRect(x: pad + 2, y: 9, width: cw - 2 * pad - bw - 10, height: 16)
        panel.invalidateShadow()
    }

    /// Rounded rect with an arrow on its right edge pointing at the card.
    private static func mask(size: CGSize, arrowY: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { _ in
            let body = NSRect(x: 0, y: 0, width: size.width - arrow, height: size.height)
            let p = NSBezierPath(roundedRect: body, xRadius: 14, yRadius: 14)
            let tip = NSBezierPath()
            tip.move(to: NSPoint(x: body.maxX - 1, y: arrowY - arrow))
            tip.line(to: NSPoint(x: size.width, y: arrowY))
            tip.line(to: NSPoint(x: body.maxX - 1, y: arrowY + arrow))
            tip.close()
            NSColor.black.setFill()
            p.fill()
            tip.fill()
            return true
        }
    }

    @objc private func footerTapped() { footerAction?() }

    @objc private func revealTapped() {
        body?.layer?.filters = nil
        reveal.removeFromSuperview()
    }
}

/// Our windows never make the app active, so buttons in them must work on the first click.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
