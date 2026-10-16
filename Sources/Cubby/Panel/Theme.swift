import AppKit

/// Design tokens for the drawer.
enum Theme {
    static let drawerWidth: CGFloat = 400
    static let inset: CGFloat = 10           // gap to the screen's top/right/bottom
    static let radius: CGFloat = 24
    static let shadowRoom: CGFloat = 30      // extra window width left of the drawer so its shadow isn't clipped
    static let railWidth: CGFloat = 56
    static let padding: CGFloat = 14
    static let hintHeight: CGFloat = 22

    static let cardRadius: CGFloat = 12
    static let cardGap: CGFloat = 8

    static let cardFill = dynamic(light: NSColor(white: 1, alpha: 0.72), dark: NSColor(white: 1, alpha: 0.06))
    static let cardHover = dynamic(light: NSColor(white: 1, alpha: 0.95), dark: NSColor(white: 1, alpha: 0.10))
    static let chipFill = dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.10))
    static let fieldFill = dynamic(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.08))
    static let railFill = dynamic(light: NSColor(white: 0, alpha: 0.035), dark: NSColor(white: 0, alpha: 0.18))
    static let hairline = dynamic(light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.12))

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    /// Window frame for a screen: right edge, full visible height, wide enough for drawer + shadow.
    static func windowFrame(visible: CGRect) -> CGRect {
        let w = drawerWidth + inset + shadowRoom
        return CGRect(x: visible.maxX - w, y: visible.minY, width: w, height: visible.height)
    }

    /// Drawer frame inside that window (window-local coordinates).
    static func drawerFrame(windowSize: CGSize) -> CGRect {
        CGRect(x: shadowRoom, y: inset, width: drawerWidth, height: windowSize.height - 2 * inset)
    }

    /// Compact card timestamp: "now", "4m", "3h", "Yesterday", "Mon", "12 Oct".
    static func shortTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(s / 3600))h" }
        if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now)!) {
            return "Yesterday"
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.dateFormat = s < 6 * 86400 ? "EEE" : "d MMM"
        return f.string(from: date)
    }

    /// Day section title for the history list.
    static func dayTitle(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now)!) { return "Yesterday" }
        let f = DateFormatter()
        f.calendar = calendar
        f.dateFormat = now.timeIntervalSince(date) < 6 * 86400 ? "EEEE" : "d MMMM"
        return f.string(from: date)
    }
}
