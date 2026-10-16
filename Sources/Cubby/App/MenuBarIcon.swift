import AppKit

/// The Cubby mark on an 18-unit grid: a drawer with two clip cards fanned out of it. Template image, so macOS tints it.
/// `Resources/make-icon.swift` draws the same geometry for the app icon.
enum MenuBarIcon {
    static func image(paused: Bool = false) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            // Two fanned cards (like the app icon), drawn as open outlines whose bottoms disappear into the drawer.
            for (cx, angle, top) in [(6.0, -13.0, 3.2), (12.0, 13.0, 3.2)] as [(CGFloat, CGFloat, CGFloat)] {
                let t = NSAffineTransform()
                t.translateX(by: cx, yBy: 9.2)
                t.rotate(byDegrees: angle)
                let card = NSBezierPath()
                card.move(to: NSPoint(x: -2.3, y: 0))
                card.appendArc(from: NSPoint(x: -2.3, y: top - 9.2), to: NSPoint(x: 2.3, y: top - 9.2), radius: 1.3)
                card.appendArc(from: NSPoint(x: 2.3, y: top - 9.2), to: NSPoint(x: 2.3, y: 0), radius: 1.3)
                card.line(to: NSPoint(x: 2.3, y: 0))
                card.transform(using: t as AffineTransform)
                card.lineWidth = 1.4
                card.lineJoinStyle = .round
                card.stroke()
            }
            NSGraphicsContext.current?.compositingOperation = .clear // erase card lines that would show inside the drawer
            NSBezierPath(roundedRect: NSRect(x: 2, y: 8.6, width: 14, height: 7.6), xRadius: 2.2, yRadius: 2.2).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.set()
            let drawer = NSBezierPath(roundedRect: NSRect(x: 2, y: 8.6, width: 14, height: 7.6), xRadius: 2.2, yRadius: 2.2)
            drawer.lineWidth = 1.6
            drawer.stroke()
            let handle = NSBezierPath()
            handle.move(to: NSPoint(x: 7, y: 12.4)); handle.line(to: NSPoint(x: 11, y: 12.4))
            handle.lineWidth = 1.6; handle.lineCapStyle = .round
            if paused { handle.setLineDash([1.2, 1.6], count: 2, phase: 0) } // a gap in the handle = paused
            handle.stroke()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = paused ? "Cubby (paused)" : "Cubby"
        return img
    }
}
