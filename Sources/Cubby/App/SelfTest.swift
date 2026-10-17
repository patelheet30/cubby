import AppKit

/// `Cubby --self-test`: asserts on the pure logic (swift-testing isn't usable without Xcode).
enum SelfTest {
    static func run() -> Never {
        var failures = 0, checks = 0
        func check(_ ok: Bool, _ what: String) { checks += 1; if !ok { failures += 1; print("FAIL: \(what)") } }

        // Secondary 1920×1080 display at x 1680 with no Dock: window hugs the right edge, full height.
        let w = Theme.windowFrame(visible: CGRect(x: 1680, y: 0, width: 1920, height: 1080))
        check(w == CGRect(x: 3600 - 440, y: 0, width: 440, height: 1080), "windowFrame \(w)")
        // Drawer sits right of the shadow room, inset 10 top/bottom (and 10 from the screen edge on the right).
        check(Theme.drawerFrame(windowSize: w.size) == CGRect(x: 30, y: 10, width: 400, height: 1060), "drawerFrame")
        // Dock visible at the bottom: the window starts above it.
        check(Theme.windowFrame(visible: CGRect(x: 0, y: 70, width: 1680, height: 950)).minY == 70, "windowFrame above Dock")

        // Card timestamps and day groups.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 15))!
        check(Theme.shortTime(now.addingTimeInterval(-20), now: now, calendar: cal) == "now", "shortTime now")
        check(Theme.shortTime(now.addingTimeInterval(-4 * 60), now: now, calendar: cal) == "4m", "shortTime minutes")
        check(Theme.shortTime(now.addingTimeInterval(-3 * 3600), now: now, calendar: cal) == "3h", "shortTime hours")
        check(Theme.shortTime(now.addingTimeInterval(-20 * 3600), now: now, calendar: cal) == "Yesterday", "shortTime yesterday")
        check(Theme.dayTitle(now.addingTimeInterval(-3600), now: now, calendar: cal) == "Today", "dayTitle today")
        check(Theme.dayTitle(now.addingTimeInterval(-26 * 3600), now: now, calendar: cal) == "Yesterday", "dayTitle yesterday")

        // Card heights: a one-line text card is shorter than a four-line one, and text is capped at four lines.
        func text(_ s: String) -> Clip { Clip(id: 1, kind: .text, date: now, appName: "A", appBundleID: nil, preview: Preview(text: s)) }
        let short = text("hi"), long = text(String(repeating: "word ", count: 100)), longer = text(String(repeating: "word ", count: 400))
        check(CardView.height(for: short, width: 320) < CardView.height(for: long, width: 320), "card height grows with text")
        check(CardView.height(for: long, width: 320) == CardView.height(for: longer, width: 320), "card text capped")

        // Typing routes printable characters to search; arrows/function keys don't.
        check(DrawerPanel.isPrintable("a") && DrawerPanel.isPrintable("é") && DrawerPanel.isPrintable(" "), "printable")
        check(!DrawerPanel.isPrintable("\u{F702}") && !DrawerPanel.isPrintable("\r") && !DrawerPanel.isPrintable(""), "non-printable")

        migrationTests(check)
        storeTests(check)
        classifierTests(check)
        linkCleanerTests(check)
        secretTests(check)

        print(failures == 0 ? "self-test: all \(checks) passed" : "self-test: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func item(_ pairs: (String, Data)...) -> [PayloadItem] {
        [PayloadItem(types: pairs.map(\.0), data: Dictionary(uniqueKeysWithValues: pairs))]
    }

    static func text(_ s: String) -> [PayloadItem] { item(("public.utf8-plain-text", Data(s.utf8))) }

    /// A database written by v0.1 (schema 1) opens in this build with its clips intact and the v2 columns added.
    static func migrationTests(_ check: (Bool, String) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cubby-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir.appending(path: "blobs"), withIntermediateDirectories: true)
        do {
            let old = DB(path: dir.appending(path: "store.sqlite").path)
            old.exec(Store.schemaV1)
            old.run("INSERT INTO pinboard (name, color, position, created_at) VALUES ('Work', 0, 0, 0)")
            old.run("INSERT INTO item (uuid, kind, checksum, preview, payload_bytes, timestamp, created_at) VALUES ('u1', 5, 'c1', ?, 0, 1, 1)",
                    [try! PropertyListEncoder.binary.encode(Preview(text: "from v1"))])
        }
        let store = Store(directory: dir)
        check(store.history().map { $0.preview.text } == ["from v1"] && store.pinboards().map(\.name) == ["Work"], "v1 → v2 keeps data")
        var columns: [String] = [], version: Int64 = 0
        let raw = DB(path: dir.appending(path: "store.sqlite").path)
        raw.run("PRAGMA table_info(item)") { columns.append($0.text(1) ?? "") }
        raw.run("PRAGMA user_version") { version = $0.int(0) }
        check(columns.contains("expires_at") && columns.contains("sensitive") && version == 2, "v2 columns added")
        check(store.history().first?.sensitive == false && store.history().first?.expiresAt == nil, "old clips aren't secrets")
    }

    static func storeTests(_ check: (Bool, String) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cubby-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir)
        func ingest(_ items: [PayloadItem], _ date: Date) -> Int64 {
            ClipboardWatcher.ingest(items, bundleID: "com.apple.Notes", appName: "Notes", date: date, store: store, latePreviews: false)!
        }
        let old = Date(timeIntervalSinceNow: -40 * 86400), now = Date()
        check(store.pinboards().map(\.name) == ["Pinned", "Useful Links"], "seed pinboards")

        // Dedupe: the same text twice is one clip, moved to the front.
        let a = ingest(text("Ship the drawer tonight"), old)
        let b = ingest(text("second clip"), old.addingTimeInterval(1))
        check(store.history().map(\.id) == [b, a], "history newest first")
        check(ingest(text("Ship the drawer tonight"), now) == a, "dedupe returns same id")
        check(store.history().map(\.id) == [a, b], "re-copy moves to front")
        check(store.payload(a) == text("Ship the drawer tonight"), "payload round trip")

        // Search: prefix words, quotes can't break the query.
        check(store.search("drawe ton").map(\.id) == [a], "fts prefix")
        check(store.search("notes").count == 2, "fts app name")
        _ = store.search("\" OR") // must not throw an FTS syntax error

        // Trim keeps pins: an old pinned clip leaves History but stays on its board; the unpinned one is gone with its blob.
        let board = store.pinboards()[0].id
        store.pin([b], to: board)
        store.touch([a], at: old)
        let blobA = store.blobURL(uuid(store, a))
        store.trim(before: Date(timeIntervalSinceNow: -30 * 86400))
        check(store.history().isEmpty, "trim empties old history")
        check(store.board(board).map(\.id) == [b], "trim keeps pinned")
        check(!FileManager.default.fileExists(atPath: blobA.path), "trim deletes blob")

        // Unpin never deletes: the pinned-only clip returns to History.
        store.unpin([b])
        check(store.history().map(\.id) == [b] && store.board(board).isEmpty, "unpin returns to history")

        // Soft delete + undo, then purge removes for real.
        let c = ingest(text("delete me"), now)
        store.delete([c])
        check(!store.history().contains { $0.id == c }, "delete hides")
        store.restore([c])
        check(store.history().contains { $0.id == c }, "undo delete")
        let blobC = store.blobURL(uuid(store, c))
        store.delete([c]); store.purge()
        check(store.payload(c) == nil && !FileManager.default.fileExists(atPath: blobC.path), "purge deletes")

        // Pinboards: pin order, move, delete removes pinned-only clips but keeps History clips (unpinned).
        let links = store.createPinboard(name: "Links")
        let d = ingest(text("in history"), now), e = ingest(text("pinned only"), now)
        store.pin([d], to: links.id); store.pin([e], to: links.id)
        check(store.board(links.id).map(\.id) == [e, d], "newest pin on top")
        store.reorder(board: links.id, [d, e])
        check(store.board(links.id).map(\.id) == [d, e], "reorder")
        store.pin([d], to: links.id)
        check(store.board(links.id).map(\.id) == [d, e], "pin idempotent")
        store.touch([e], at: old); store.trim(before: Date(timeIntervalSinceNow: -86400)) // e is now pinned-only
        store.deletePinboard(links.id)
        check(!store.pinboards().contains { $0.id == links.id }, "board deleted")
        check(store.history().first { $0.id == d }?.pinboard == nil, "history clip loses deleted board tag")
        store.restorePinboard(links.id)
        check(store.board(links.id).map(\.id) == [d, e], "undo board delete")
        store.deletePinboard(links.id); store.purge()
        check(store.payload(e) == nil && store.history().contains { $0.id == d }, "purged board keeps history clip")
        store.movePinboard(store.pinboards()[1].id, by: -1)
        check(store.pinboards().map(\.name) == ["Useful Links", "Pinned"], "move pinboard")

        // Structured filters: kind, app, date.
        let f1 = ClipboardWatcher.ingest(text("https://example.com/"), bundleID: "com.apple.Safari", appName: "Safari", date: now, store: store, latePreviews: false)!
        check(store.search("", filter: Filter(kinds: [.link])).map(\.id) == [f1], "filter kind")
        check(store.search("", filter: Filter(apps: ["com.apple.Safari"])).map(\.id) == [f1], "filter app")
        check(store.search("paste", filter: Filter(kinds: [.text])).isEmpty, "filter + text")
        check(store.search("", filter: Filter(date: .yesterday)).isEmpty && !store.search("", filter: Filter(date: .today)).isEmpty, "filter date")
        check(store.topApps().first?.name == "Notes", "top apps")

        // Pinboards that follow apps: bind, rebind moves, unbind, a deleted board stops matching (and its bindings go on purge).
        let shell = store.createPinboard(name: "Shell"), replies = store.createPinboard(name: "Replies")
        store.bindApp("com.apple.Terminal", to: shell.id)
        store.bindApp("com.tinyspeck.slackmacgap", to: replies.id)
        check(store.board(forApp: "com.apple.Terminal") == shell.id && store.pinboards().first { $0.id == shell.id }?.apps == ["com.apple.Terminal"], "bind app")
        store.bindApp("com.apple.Terminal", to: replies.id)
        check(store.board(forApp: "com.apple.Terminal") == replies.id && store.pinboards().first { $0.id == shell.id }?.apps == [], "rebind moves the app")
        store.unbindApp("com.apple.Terminal")
        check(store.board(forApp: "com.apple.Terminal") == nil && store.board(forApp: "com.safari") == nil, "unbind")
        store.deletePinboard(replies.id)
        check(store.board(forApp: "com.tinyspeck.slackmacgap") == nil, "deleted board stops matching")
        store.restorePinboard(replies.id)
        check(store.board(forApp: "com.tinyspeck.slackmacgap") == replies.id, "undo restores binding")
        store.deletePinboard(replies.id); store.purge()
        store.bindApp("com.tinyspeck.slackmacgap", to: shell.id)
        check(store.board(forApp: "com.tinyspeck.slackmacgap") == shell.id, "purged board's binding is gone (app free to rebind)")

        // Rename is searchable; erase keeps pins.
        store.rename(d, to: "  Address  ")
        check(store.history().first { $0.id == d }?.title == "Address" && store.search("addr").map(\.id) == [d], "rename + search")
        store.pin([d], to: board)
        store.eraseHistory()
        check(store.history().isEmpty && store.board(board).map(\.id) == [d], "erase keeps pins")
    }

    private static func uuid(_ store: Store, _ id: Int64) -> String { store.uuid(of: id) ?? "" }

    static func secretTests(_ check: (Bool, String) -> Void) {
        typealias K = SecretDetector.Kind
        // Fake keys are assembled at runtime so nothing key-shaped sits in the source (and trips secret scanners).
        func fake(_ a: String, _ b: String) -> String { a + b }
        let stripe = fake("sk_", "live_" + String(repeating: "x7Q", count: 8)), github = fake("ghp_", String(repeating: "aB3", count: 12))
        let yes: [(String, K)] = [
            (fake("sk-ant-", "api03-Abc123Def456Ghi789Jkl012Mno345"), .apiKey),
            ("OPENAI_API_KEY=" + fake("sk-", "proj-AbCdEfGhIjKlMnOpQrStUvWx"), .apiKey),
            (stripe, .apiKey),
            (github, .apiKey),
            (fake("xox", "b-123456789012-abcdefghijkl"), .apiKey),
            (fake("AKIA", "IOSFODNN7EXAMPLE"), .apiKey),
            (fake("AIza", "SyA1234567890abcdefghijklmnopqrstuv"), .apiKey),
            (fake("-----BEGIN OPENSSH PRIV", "ATE KEY-----\nAAAA\n-----END"), .privateKey),
            (fake("eyJhbGciOiJIUzI1NiJ9.", "eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"), .token),
            ("4242 4242 4242 4242", .card),
            ("378282246310005", .card),
            ("482913", .code),
            ("Your verification code is 4821. Don't share it.", .code),
            ("q7Zx_2pLm9Vt4Rw8Ks1Nf6Hb3Yd5Jc0Ga", .token),
        ]
        for (text, kind) in yes { check(SecretDetector.check(text) == kind, "secret: \(text.prefix(24)) → \(kind.rawValue)") }
        let no = ["£249,000", "550e8400-e29b-41d4-a716-446655440000", "a94a8fe5ccb19ba61c4c0873d391e987982fbbd3",
                  "pneumonoultramicroscopicsilicovolcanoconiosis", "2024", "4242 4242 4242 4241", "Call me at 7pm",
                  "https://example.com/path?token=abcdefghijklmnopqrstuvwxyz0123456789", "Ship the drawer tonight"]
        for text in no { check(SecretDetector.check(text) == nil, "not a secret: \(text.prefix(24))") }

        // Expiry: an unpinned secret goes when its time is up; a pinned one stays; ordinary text never expires.
        let dir = FileManager.default.temporaryDirectory.appending(path: "cubby-secrets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir)
        let past = Date(timeIntervalSinceNow: -700)
        func ingest(_ s: String, _ date: Date) -> Int64 {
            ClipboardWatcher.ingest(text(s), bundleID: nil, appName: nil, date: date, store: store, latePreviews: false,
                                    detectSecrets: true, secretLifetime: 600)!
        }
        let key = ingest(stripe, past), kept = ingest(github, past)
        let plain = ingest("just a note", past)
        let k = store.history().first { $0.id == key }
        check(k?.sensitive == true && k?.expiresAt.map { abs($0.timeIntervalSince(past) - 600) < 1 } == true, "secret marked with expiry")
        check(store.search("sk_live").isEmpty && store.search("secret").count == 2, "secrets searchable only as 'secret'")
        store.pin([kept], to: store.pinboards()[0].id)
        check(store.board(store.pinboards()[0].id).first?.expiresAt == nil, "pinning clears the countdown")
        let gone = store.expireSecrets()
        let ids = store.history().map(\.id)
        check(gone == [stripe] && !ids.contains(key) && ids.contains(kept) && ids.contains(plain), "expiry deletes only unpinned secrets")
        store.unpin([kept], secretLifetime: 600)
        check((store.history().first { $0.id == kept }?.expiresAt?.timeIntervalSinceNow ?? 0) > 590, "unpinning restarts the countdown")
        let again = ingest(github, Date())
        check(again == kept && (store.history().first { $0.id == kept }?.expiresAt?.timeIntervalSinceNow ?? 0) > 590, "re-copy restarts the countdown")
    }

    static func linkCleanerTests(_ check: (Bool, String) -> Void) {
        let cases: [(String, String?, Int)] = [ // input, cleaned (nil = untouched), trackers removed
            ("https://example.com/page?utm_source=x&utm_medium=y&id=7", "https://example.com/page?id=7", 2),
            ("https://example.com/?fbclid=abc", "https://example.com/", 1),
            ("https://shop.example/p?gclid=1&msclkid=2&color=red#reviews", "https://shop.example/p?color=red#reviews", 2),
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=XYZ&pp=abc", "https://www.youtube.com/watch?v=dQw4w9WgXcQ", 2),
            ("https://youtu.be/dQw4w9WgXcQ?si=XYZ", "https://youtu.be/dQw4w9WgXcQ", 1),
            ("https://open.spotify.com/track/123?si=abc", "https://open.spotify.com/track/123", 1),
            ("https://x.com/user/status/1?s=20&t=abc", "https://x.com/user/status/1", 2),
            ("https://www.instagram.com/p/xyz/?igsh=abc", "https://www.instagram.com/p/xyz/", 1),
            ("https://www.amazon.co.uk/Some-Long-Name/dp/B0ABCDEFGH/ref=sr_1_1?keywords=x&tag=y", "https://www.amazon.co.uk/dp/B0ABCDEFGH", 3),
            ("https://www.amazon.com/dp/B0ABCDEFGH", nil, 0),
            ("https://example.com/search?q=swift&s=2&t=10", nil, 0),          // s/t only track on X
            ("https://example.com/page?id=7", nil, 0),
            ("https://example.com/", nil, 0),
            ("ftp://example.com/?utm_source=x", nil, 0),
        ]
        for (input, want, n) in cases {
            let got = LinkCleaner.clean(input)
            check(got?.url == want && (got?.removed ?? 0) == n, "clean \(input) → \(got?.url ?? "untouched")")
        }
        // A copied link is rewritten in place; text that isn't a lone link is left alone.
        let copied = item(("public.utf8-plain-text", Data("https://example.com/?utm_source=x".utf8)), ("public.rtf", Data("x".utf8)))
        let c = LinkCleaner.clean(copied)
        check(c?.original == "https://example.com/?utm_source=x" && c?.items[0].data["public.utf8-plain-text"] == Data("https://example.com/".utf8)
              && c?.items[0].types == ["public.utf8-plain-text"], "pasteboard link rewritten, rich copy dropped")
        check(LinkCleaner.clean(text("read https://example.com/?utm_source=x")) == nil, "link inside text untouched")

        // Merge Clips: order kept, blanks dropped, each format.
        let parts = ["first", "  second line\nwraps ", "", "#FF5500"]
        check(MergeStyle.lines.join(parts) == "first\nsecond line\nwraps\n#FF5500", "merge lines")
        check(MergeStyle.bullets.join(parts) == "• first\n• second line\nwraps\n• #FF5500", "merge bullets")
        check(MergeStyle.commas.join(parts) == "first, second line\nwraps, #FF5500", "merge commas")
        check(MergeStyle.paragraph.join(parts) == "first second line wraps #FF5500", "merge paragraph")
    }

    static func classifierTests(_ check: (Bool, String) -> Void) {
        func kind(_ items: [PayloadItem]) -> ItemKind { Classifier.analyze(items).kind }
        check(kind(text("hello world")) == .text, "classify text")
        check(kind(text("https://example.com/")) == .link, "classify link")
        check(kind(text("see https://example.com/")) == .text, "url inside text is text")
        check(kind(text("ftp://x.org")) == .text, "non-http url is text")
        check(kind(text(" #ff5500\n")) == .color && Classifier.analyze(text("ff5500")).string == "#FF5500", "classify color")
        check(kind(item(("public.file-url", Data("file:///Applications/Safari.app/".utf8)))) == .file, "classify file")
        check(kind(item(("com.example.custom", Data([1, 2, 3])))) == .unknown, "classify unknown")

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 3,
                                   hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        let img = item(("public.png", png), ("public.utf8-plain-text", Data("caption".utf8)))
        check(kind(img) == .image, "classify image (beats its text)")
        let (p, _) = Classifier.preview(Classifier.analyze(img), img)
        let thumb = p.thumb.flatMap { NSBitmapImageRep(data: $0) }
        check(p.w == 800 && p.h == 400 && thumb?.pixelsWide == 800, "image preview size + thumb (no upscaling)")

        // A single image file (what screenshot apps put on the clipboard) is an image clip, previewed from disk.
        let pngURL = FileManager.default.temporaryDirectory.appending(path: "cubby-selftest-\(UUID().uuidString).png")
        try? png.write(to: pngURL)
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let shot = item(("public.file-url", Data(pngURL.absoluteString.utf8)))
        let sp = Classifier.preview(Classifier.analyze(shot), shot).0
        check(kind(shot) == .image && sp.w == 800 && sp.thumb != nil && sp.paths == [pngURL.path], "image file is an image clip")
        let two = [shot[0], PayloadItem(types: ["public.file-url"], data: ["public.file-url": Data("file:///Applications/Safari.app/".utf8)])]
        check(kind(two) == .file, "several files stay a file clip")

        let file = item(("public.file-url", Data("file:///Applications/Safari.app/".utf8)))
        check(Classifier.preview(Classifier.analyze(file), file).0.paths == ["/Applications/Safari.app"], "file paths")
        let link = item(("public.utf8-plain-text", Data("https://x.org".utf8)), ("public.url-name", Data("X".utf8)))
        check(Classifier.preview(Classifier.analyze(link), link).0.title == "X", "link title from Safari")
        let t = Classifier.preview(Classifier.analyze(text("a b\nc")), text("a b\nc")).0
        check(t.textLength == 5 && t.lines == 2 && t.words == 3, "text counts")

        check(ClipboardWatcher.skipReason(types: ["org.nspasteboard.ConcealedType"], bundleID: nil) != nil, "skip concealed")
        check(ClipboardWatcher.skipReason(types: ["public.utf8-plain-text"], bundleID: "com.apple.Passwords") != nil, "skip passwords app")
        check(ClipboardWatcher.skipReason(types: ["public.utf8-plain-text"], bundleID: "com.apple.Notes") == nil, "keep normal copy")
        let apps = [(bundleID: "com.apple.mail", name: "Mail"), (bundleID: "com.apple.DigitalColorMeter", name: "Digital Color Meter")]
        let boards = [Pinboard(id: 7, name: "Work", rgb: 0)]
        let p1 = SearchTokens.peel("mail links meeting sli", apps: apps, boards: boards)
        check(p1 == SearchTokens.Peeled(text: "meeting sli", kinds: [.link], apps: ["com.apple.mail"]), "peel kind + app \(p1)")
        check(SearchTokens.peel("link", apps: apps, boards: boards).kinds.isEmpty, "unfinished word stays text")
        check(SearchTokens.peel("digital work ", apps: apps, boards: boards) == SearchTokens.Peeled(text: "", apps: ["com.apple.DigitalColorMeter"], board: 7),
              "peel app first word + board")
        check(SearchTokens.peel("hello world", apps: apps, boards: boards).text == "hello world", "plain text untouched")
        check(Store.ftsQuery("a \"b") == "\"a\"* \"\"\"b\"*", "fts escaping")
    }
}
