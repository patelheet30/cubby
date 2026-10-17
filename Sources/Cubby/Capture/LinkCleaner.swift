import Foundation

/// Strips tracking from links: generic campaign/click IDs everywhere, plus a few site-specific rules.
enum LinkCleaner {
    static let trackers: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "ttclid", "twclid", "li_fat_id",
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "igshid", "igsh", "ref_src", "spm", "_gl",
    ]
    static let trackerPrefixes = ["utm_", "vero_", "oly_"]

    /// Parameters that only mean "tracking" on certain sites (elsewhere `s` or `t` can be real).
    static func siteTrackers(_ host: String) -> Set<String> {
        if host.hasSuffix("youtube.com") || host == "youtu.be" { return ["si", "pp", "feature"] }
        if host.hasSuffix("spotify.com") { return ["si", "context"] }
        if host == "x.com" || host.hasSuffix(".x.com") || host.hasSuffix("twitter.com") { return ["s", "t"] }
        if host.hasSuffix("instagram.com") || host.hasSuffix("threads.net") { return ["igsh", "img_index"] }
        if host.hasSuffix("linkedin.com") { return ["trk", "trackingId", "refId", "lipi"] }
        return []
    }

    /// The cleaned link and how many trackers were removed, or nil when there's nothing to clean.
    static func clean(_ link: String) -> (url: String, removed: Int)? {
        guard var c = URLComponents(string: link), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host?.lowercased() else { return nil }
        var removed = 0

        // Amazon product pages: everything but /dp/<ASIN> is tracking (ref=, tag=, the product-name slug).
        if host.contains("amazon."), let asin = amazonASIN(c.path) {
            let n = (c.queryItems?.count ?? 0) + (c.path == "/dp/\(asin)" ? 0 : 1)
            guard n > 0 else { return nil }
            return ("https://\(c.host!)/dp/\(asin)", n)
        }

        if let items = c.queryItems, !items.isEmpty {
            let site = siteTrackers(host)
            let kept = items.filter { q in
                let name = q.name.lowercased()
                let tracking = trackers.contains(name) || site.contains(q.name) || trackerPrefixes.contains { name.hasPrefix($0) }
                if tracking { removed += 1 }
                return !tracking
            }
            c.queryItems = kept.isEmpty ? nil : kept
        }
        guard removed > 0, let out = c.string else { return nil }
        return (out, removed)
    }

    private static func amazonASIN(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        for (i, p) in parts.enumerated() where (p == "dp" || p == "product") && i + 1 < parts.count {
            let asin = parts[i + 1]
            if asin.count == 10, asin.allSatisfy({ $0.isLetter || $0.isNumber }) { return String(asin) }
        }
        return nil
    }

    /// Rewrites a single-item pasteboard snapshot whose content is one link. Returns the new snapshot plus the original link.
    static func clean(_ items: [PayloadItem]) -> (items: [PayloadItem], original: String, removed: Int)? {
        guard items.count == 1, var item = items.first else { return nil }
        let text = item.data["public.utf8-plain-text"].flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = item.data["public.url"].flatMap { String(data: $0, encoding: .utf8) }
        guard let original = url ?? text.flatMap(Classifier.singleURL), let (cleaned, removed) = clean(original) else { return nil }
        for t in ["public.utf8-plain-text", "public.url"] where item.data[t] != nil {
            item.data[t] = Data(cleaned.utf8)
        }
        // Rich copies (Safari's WebURLsWithTitles, HTML) still carry the tracked link, so keep only the plain forms.
        item.types = item.types.filter { ["public.utf8-plain-text", "public.url", "public.url-name"].contains($0) }
        item.data = item.data.filter { item.types.contains($0.key) }
        return ([item], original, removed)
    }
}
