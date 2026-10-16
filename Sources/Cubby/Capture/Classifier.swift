import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Pasteboard snapshot → kind, dedupe checksum, card preview, search text. Pure and synchronous (runs on the capture queue).
enum Classifier {
    static let imageTypes = ["public.png", "public.tiff", "public.jpeg", "public.heic"]
    /// Sharp on a Retina card (≈ 600 px wide, up to 260 pt tall); link images and file thumbnails only need `smallThumb`.
    static let thumbMax = 1024
    static let smallThumb = 192

    struct Result {
        var kind: ItemKind
        var checksum: String
        var string: String?   // the text, URL or hex, when there is one
    }

    /// Cheap part: decides the kind and checksum, so duplicates can be bumped before any thumbnail work.
    static func analyze(_ items: [PayloadItem]) -> Result {
        let fileURLs = items.compactMap { $0.data["public.file-url"].flatMap { String(data: $0, encoding: .utf8) } }
        if !fileURLs.isEmpty { return Result(kind: .file, checksum: md5(Data(fileURLs.joined(separator: "\n").utf8)), string: nil) }

        if let img = imageData(items) { return Result(kind: .image, checksum: md5(img), string: nil) }

        if let s = string(items) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let sum = md5(Data(s.utf8))
            if t.range(of: "^#?[0-9A-Fa-f]{6}$", options: .regularExpression) != nil {
                return Result(kind: .color, checksum: sum, string: t.hasPrefix("#") ? t.uppercased() : "#" + t.uppercased())
            }
            if let url = singleURL(t) ?? items.first?.data["public.url"].flatMap({ String(data: $0, encoding: .utf8) }) {
                return Result(kind: .link, checksum: sum, string: url)
            }
            return Result(kind: .text, checksum: sum, string: s)
        }

        var blob = Data()
        for it in items { for t in it.types { blob += Data(t.utf8); blob += it.data[t] ?? Data() } }
        return Result(kind: .unknown, checksum: md5(blob), string: nil)
    }

    /// Expensive part: thumbnails, counts, link title. Returns the preview and what FTS should index.
    static func preview(_ r: Result, _ items: [PayloadItem]) -> (Preview, String) {
        var p = Preview()
        switch r.kind {
        case .text:
            let s = r.string ?? ""
            p.text = String(s.prefix(500))
            p.textLength = s.count
            p.lines = s.split(whereSeparator: \.isNewline).count
            p.words = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            return (p, s)
        case .link:
            p.url = r.string
            p.title = items.first?.data["public.url-name"].flatMap { String(data: $0, encoding: .utf8) }
            return (p, [r.string, p.title].compactMap { $0 }.joined(separator: " "))
        case .color:
            p.hex = r.string
            return (p, r.string ?? "")
        case .image:
            if let data = imageData(items), let src = CGImageSourceCreateWithData(data as CFData, nil) {
                let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
                p.w = props?[kCGImagePropertyPixelWidth] as? Int
                p.h = props?[kCGImagePropertyPixelHeight] as? Int
                p.thumb = thumbnail(src)
            }
            return (p, "")
        case .file:
            let paths = items.compactMap { $0.data["public.file-url"].flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:))?.path }
            p.paths = paths
            p.totalSize = paths.reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1)[.size] as? Int) ?? 0) }
            return (p, paths.map { ($0 as NSString).lastPathComponent }.joined(separator: " "))
        case .unknown:
            p.types = items.flatMap(\.types)
            return (p, "")
        }
    }

    // MARK: helpers

    static func md5(_ d: Data) -> String { Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static func imageData(_ items: [PayloadItem]) -> Data? {
        for t in imageTypes { if let d = items.first(where: { $0.data[t] != nil })?.data[t] { return d } }
        return nil
    }

    /// Plain text across all items (multi-item copies join with newlines); RTF as a fallback.
    static func string(_ items: [PayloadItem]) -> String? {
        let plain = items.compactMap { $0.data["public.utf8-plain-text"].flatMap { String(data: $0, encoding: .utf8) } }
        if !plain.isEmpty { return plain.joined(separator: "\n") }
        if let rtf = items.first(where: { $0.data["public.rtf"] != nil })?.data["public.rtf"] {
            return NSAttributedString(rtf: rtf, documentAttributes: nil)?.string
        }
        return nil
    }

    /// The whole (trimmed) string is one http(s) URL.
    static func singleURL(_ s: String) -> String? {
        guard !s.isEmpty, !s.contains(where: \.isWhitespace),
              let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let m = det.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.range.length == (s as NSString).length,
              let scheme = m.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return s
    }

    /// ≤ `max` px on the long side; JPEG, or PNG when there's transparency.
    static func thumbnail(_ src: CGImageSource, max: Int = thumbMax) -> Data? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return encode(cg)
    }

    static func thumbnail(_ image: NSImage, max: Int = smallThumb) -> Data? {
        guard let tiff = image.tiffRepresentation, let src = CGImageSourceCreateWithData(tiff as CFData, nil) else { return nil }
        return thumbnail(src, max: max)
    }

    static func encode(_ cg: CGImage) -> Data? {
        let alpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo)
        let out = NSMutableData()
        let type = (alpha ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dst = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}
