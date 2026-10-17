import AppKit

/// Stored as integers in `item.kind`; the numbers must never change.
enum ItemKind: Int, CaseIterable { case unknown, image, color, file, link, text

    var label: String {
        switch self {
        case .unknown: "Unknown"
        case .image: "Image"
        case .color: "Color"
        case .file: "File"
        case .link: "Link"
        case .text: "Text"
        }
    }
}

/// How Merge Clips joins several clips into one.
enum MergeStyle: CaseIterable {
    case lines, bullets, commas, paragraph

    var title: String {
        switch self {
        case .lines: "Lines"
        case .bullets: "Bullet List"
        case .commas: "Comma-Separated"
        case .paragraph: "One Paragraph"
        }
    }

    func join(_ parts: [String]) -> String {
        let p = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        switch self {
        case .lines: return p.joined(separator: "\n")
        case .bullets: return p.map { "• " + $0 }.joined(separator: "\n")
        case .commas: return p.joined(separator: ", ")
        case .paragraph: return p.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " ")
        }
    }
}

/// Structured search filters (the tray chips, or words like "link" / "safari" typed into search).
struct Filter: Equatable {
    var kinds: Set<ItemKind> = []
    var apps: Set<String> = []          // bundle IDs
    var date: DateFilter? = nil
    var isEmpty: Bool { kinds.isEmpty && apps.isEmpty && date == nil }
}

enum DateFilter: Int, CaseIterable {
    case today, yesterday, week, month

    var label: String { ["Today", "Yesterday", "Last 7 Days", "Last 30 Days"][rawValue] }

    func range(now: Date = Date(), calendar: Calendar = .current) -> Range<Date> {
        let today = calendar.startOfDay(for: now), end = now.addingTimeInterval(1)
        switch self {
        case .today: return today..<end
        case .yesterday: return calendar.date(byAdding: .day, value: -1, to: today)!..<today
        case .week: return now.addingTimeInterval(-7 * 86400)..<end
        case .month: return now.addingTimeInterval(-30 * 86400)..<end
        }
    }
}

struct Pinboard: Equatable {
    var id: Int64
    var name: String
    var rgb: Int
    var color: NSColor { NSColor(rgb: rgb) }
}

/// One `NSPasteboardItem`, every type in the order the source app wrote them.
struct PayloadItem: Codable, Equatable {
    var types: [String]
    var data: [String: Data]
}

extension PayloadItem {
    var pasteboardItem: NSPasteboardItem {
        let p = NSPasteboardItem()
        for t in types { if let d = data[t] { p.setData(d, forType: .init(t)) } }
        return p
    }
}

/// The small, card-sized summary stored with each row. Which fields are set depends on the kind.
struct Preview: Codable, Equatable {
    var text: String? = nil          // text: first 500 characters
    var textLength: Int? = nil
    var lines: Int? = nil
    var words: Int? = nil
    var thumb: Data? = nil           // image thumb, link og-image, file thumbnail (JPEG/PNG)
    var w: Int? = nil                // image pixel size
    var h: Int? = nil
    var url: String? = nil           // link
    var title: String? = nil         // link page title
    var originalURL: String? = nil   // link before the Link Cleaner removed tracking
    var trackersRemoved: Int? = nil
    var hex: String? = nil           // color
    var paths: [String]? = nil       // files
    var totalSize: Int? = nil
    var types: [String]? = nil       // unknown
}

/// A row as the drawer sees it.
struct Clip {
    var id: Int64
    var kind: ItemKind
    var date: Date
    var appName: String
    var appBundleID: String?
    var customTitle: String? = nil   // user rename
    var preview = Preview()
    var pinboard: Pinboard? = nil
    var sensitive = false            // looks like a secret: blurred in the drawer
    var expiresAt: Date? = nil       // deleted after this, unless pinned

    var title: String? { customTitle ?? (kind == .link ? preview.title : nil) }

    /// Text body, link URL, or colour hex.
    var text: String? {
        switch kind {
        case .text: preview.text
        case .link: preview.url
        case .color: preview.hex
        default: nil
        }
    }

    var color: NSColor? { preview.hex.flatMap(NSColor.init(hex:)) }
    var paths: [String] { preview.paths ?? [] }
    var pixelSize: CGSize? { preview.w.map { CGSize(width: $0, height: preview.h ?? 0) } }

    private static let images = NSCache<NSString, NSImage>()

    /// Image thumb, link og-image, or file thumbnail/icon (decoded once).
    var image: NSImage? {
        let key = "\(id)-\(preview.thumb?.count ?? 0)" as NSString
        if let hit = Self.images.object(forKey: key) { return hit }
        let img = preview.thumb.flatMap(NSImage.init(data:)) ?? (kind == .file ? paths.first.map(NSWorkspace.shared.icon(forFile:)) : nil)
        if let img { Self.images.setObject(img, forKey: key) }
        return img
    }

    /// Bottom-line metric: "560 characters", "1920 × 1080", "example.com", "/Applications".
    var metric: String {
        switch kind {
        case .text: let n = preview.textLength ?? text?.count ?? 0; return "\(n.formatted()) character\(n == 1 ? "" : "s")"
        case .image: return pixelSize.map { "\(Int($0.width)) × \(Int($0.height))" } ?? ""
        case .link: return text.flatMap { URL(string: $0)?.host() } ?? ""
        case .file: return paths.count == 1 ? (paths[0] as NSString).deletingLastPathComponent : "\(paths.count) files"
        case .color, .unknown: return ""
        }
    }

    private static var icons: [String: NSImage] = [:]

    var appIcon: NSImage? {
        guard let id = appBundleID else { return nil }
        if let hit = Self.icons[id] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        Self.icons[id] = icon
        return icon
    }
}

extension NSColor {
    convenience init(rgb: Int) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    /// "#FF5500" or "FF5500".
    convenience init?(hex: String) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        self.init(rgb: v)
    }
}
