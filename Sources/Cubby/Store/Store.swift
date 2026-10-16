import AppKit
import SQLite3

private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin SQLite handle: statements with positional `?` args, rows handed to a closure.
final class DB {
    private var h: OpaquePointer?

    init(path: String) {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK else { fatalError("sqlite open \(path): \(message)") }
    }

    deinit { sqlite3_close(h) }

    var message: String { String(cString: sqlite3_errmsg(h)) }
    var lastID: Int64 { sqlite3_last_insert_rowid(h) }

    struct Row {
        let s: OpaquePointer
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(s, i) }
        func double(_ i: Int32) -> Double? { isNull(i) ? nil : sqlite3_column_double(s, i) }
        func text(_ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
        func data(_ i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(s, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
        }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(s, i) == SQLITE_NULL }
    }

    func exec(_ sql: String) {
        if sqlite3_exec(h, sql, nil, nil, nil) != SQLITE_OK { fatalError("sqlite exec: \(message)\n\(sql)") }
    }

    /// Runs one statement. Returns the number of rows changed.
    @discardableResult
    func run(_ sql: String, _ args: [Any?] = [], each: (Row) -> Void = { _ in }) -> Int {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK, let s = st else { fatalError("sqlite prepare: \(message)\n\(sql)") }
        defer { sqlite3_finalize(s) }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case .none: sqlite3_bind_null(s, n)
            case let v as Int: sqlite3_bind_int64(s, n, Int64(v))
            case let v as Int64: sqlite3_bind_int64(s, n, v)
            case let v as Double: sqlite3_bind_double(s, n, v)
            case let v as String: sqlite3_bind_text(s, n, v, -1, TRANSIENT)
            case let v as Data:
                if v.isEmpty { sqlite3_bind_zeroblob(s, n, 0) } else {
                    _ = v.withUnsafeBytes { sqlite3_bind_blob(s, n, $0.baseAddress, Int32($0.count), TRANSIENT) }
                }
            default: fatalError("sqlite bind \(type(of: a!))")
            }
        }
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW { each(Row(s: s)); continue }
            if rc != SQLITE_DONE { log("sqlite step \(rc): \(message) — \(sql)") }
            break
        }
        return Int(sqlite3_changes(h))
    }
}

/// Everything Cubby keeps: `store.sqlite` (rows, previews, FTS) + `blobs/<uuid>.lzfse` (the full pasteboard payload).
/// Thread-safe: the watcher inserts from its queue, the drawer reads on main.
final class Store: @unchecked Sendable {
    static let shared = Store(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Cubby"))
    static let changed = Notification.Name("CubbyStoreChanged")

    /// Pinboard swatches, in the order new boards take them.
    static let swatches: [Int] = [0xEEC34F, 0xF16A60, 0x4DA3F7, 0x6FCF6A, 0xA78BF5, 0xF5A142, 0x4FC6C9, 0xF07AB0]

    let dir: URL
    private let db: DB
    private let lock = NSRecursiveLock()

    init(directory: URL) {
        dir = directory
        try? FileManager.default.createDirectory(at: directory.appending(path: "blobs"), withIntermediateDirectories: true)
        db = DB(path: directory.appending(path: "store.sqlite").path)
        db.exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
        migrate()
    }

    private func migrate() {
        var version: Int64 = 0
        db.run("PRAGMA user_version") { version = $0.int(0) }
        guard version == 0 else { return }
        db.exec("""
        BEGIN;
        CREATE TABLE app (id INTEGER PRIMARY KEY, bundle_id TEXT UNIQUE NOT NULL, name TEXT NOT NULL);
        CREATE TABLE pinboard (
          id INTEGER PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL, position INTEGER NOT NULL,
          created_at REAL NOT NULL, deleted_at REAL);
        CREATE TABLE item (
          id INTEGER PRIMARY KEY, uuid TEXT UNIQUE NOT NULL, kind INTEGER NOT NULL, checksum TEXT NOT NULL,
          title TEXT, preview BLOB NOT NULL, payload_bytes INTEGER NOT NULL,
          timestamp REAL,            -- NULL = not in history (pinned only)
          created_at REAL NOT NULL,
          app_id INTEGER REFERENCES app(id),
          pinboard_id INTEGER REFERENCES pinboard(id) ON DELETE SET NULL,
          pin_order INTEGER NOT NULL DEFAULT 0,
          deleted_at REAL);          -- soft delete, so ⌘Z can bring it back; purged later
        CREATE INDEX item_ts ON item(timestamp DESC) WHERE timestamp IS NOT NULL;
        CREATE INDEX item_pin ON item(pinboard_id, pin_order) WHERE pinboard_id IS NOT NULL;
        CREATE UNIQUE INDEX item_checksum ON item(checksum);
        CREATE VIRTUAL TABLE item_fts USING fts5(body, title, meta, tokenize = 'unicode61 remove_diacritics 2');
        PRAGMA user_version = 1;
        COMMIT;
        """)
        let now = Date().timeIntervalSince1970
        db.run("INSERT INTO pinboard (name, color, position, created_at) VALUES ('Pinned', ?, 0, ?), ('Useful Links', ?, 1, ?)",
               [Self.swatches[0], now, Self.swatches[1], now])
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    func blobURL(_ uuid: String) -> URL { dir.appending(path: "blobs/\(uuid).lzfse") }

    // MARK: reading

    private static let select = """
        SELECT i.id, i.kind, i.title, i.preview, i.timestamp, i.created_at, a.name, a.bundle_id, p.id, p.name, p.color
        FROM item i LEFT JOIN app a ON a.id = i.app_id
        LEFT JOIN pinboard p ON p.id = i.pinboard_id AND p.deleted_at IS NULL
        WHERE i.deleted_at IS NULL
        """

    private func clips(_ whereSQL: String, _ args: [Any?]) -> [Clip] {
        var out: [Clip] = []
        locked {
            db.run(Self.select + " " + whereSQL, args) { r in
                let preview = (try? PropertyListDecoder().decode(Preview.self, from: r.data(3) ?? Data())) ?? Preview()
                let board = r.isNull(8) ? nil : Pinboard(id: r.int(8), name: r.text(9) ?? "", rgb: Int(r.int(10)))
                out.append(Clip(id: r.int(0), kind: ItemKind(rawValue: Int(r.int(1))) ?? .unknown,
                                date: Date(timeIntervalSince1970: r.double(4) ?? r.double(5) ?? 0),
                                appName: r.text(6) ?? "Unknown", appBundleID: r.text(7),
                                customTitle: r.text(2), preview: preview, pinboard: board))
            }
        }
        return out
    }

    // ponytail: one page of the newest clips; add paging when histories this long feel slow.
    func history(limit: Int = 1000) -> [Clip] { search("", limit: limit) }

    func board(_ id: Int64) -> [Clip] { search("", board: id) }

    /// History (or one pinboard), narrowed by full-text words (each a prefix match) and the structured filter.
    func search(_ query: String, filter: Filter = Filter(), board: Int64? = nil, limit: Int = 1000) -> [Clip] {
        var sql: [String] = [], args: [Any?] = []
        if let board { sql.append("AND i.pinboard_id = ?"); args.append(board) } else { sql.append("AND i.timestamp IS NOT NULL") }
        let fts = Self.ftsQuery(query)
        if !fts.isEmpty { sql.append("AND i.id IN (SELECT rowid FROM item_fts WHERE item_fts MATCH ?)"); args.append(fts) }
        if !filter.kinds.isEmpty {
            sql.append("AND i.kind IN (\(filter.kinds.map { _ in "?" }.joined(separator: ",")))")
            args += filter.kinds.map(\.rawValue)
        }
        if !filter.apps.isEmpty {
            sql.append("AND a.bundle_id IN (\(filter.apps.map { _ in "?" }.joined(separator: ",")))")
            args += filter.apps.map { $0 }
        }
        if let range = filter.date?.range() {
            sql.append("AND COALESCE(i.timestamp, i.created_at) >= ? AND COALESCE(i.timestamp, i.created_at) < ?")
            args += [range.lowerBound.timeIntervalSince1970, range.upperBound.timeIntervalSince1970]
        }
        sql.append(board == nil ? "ORDER BY i.timestamp DESC LIMIT ?" : "ORDER BY i.pin_order DESC LIMIT ?")
        args.append(limit)
        return clips(sql.joined(separator: " "), args)
    }

    /// Apps with the most clips, for the filter tray.
    func topApps(limit: Int = 6) -> [(bundleID: String, name: String)] {
        var out: [(String, String)] = []
        locked {
            db.run("""
                SELECT a.bundle_id, a.name FROM item i JOIN app a ON a.id = i.app_id WHERE i.deleted_at IS NULL
                GROUP BY a.id ORDER BY COUNT(*) DESC LIMIT ?
                """, [limit]) { out.append(($0.text(0) ?? "", $0.text(1) ?? "")) }
        }
        return out
    }

    /// `meet sli` → `"meet"* "sli"*` (quotes escaped, so user text can't inject FTS syntax).
    static func ftsQuery(_ q: String) -> String {
        q.split(whereSeparator: \.isWhitespace).map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " ")
    }

    func pinboards() -> [Pinboard] {
        var out: [Pinboard] = []
        locked {
            db.run("SELECT id, name, color FROM pinboard WHERE deleted_at IS NULL ORDER BY position") {
                out.append(Pinboard(id: $0.int(0), name: $0.text(1) ?? "", rgb: Int($0.int(2))))
            }
        }
        return out
    }

    /// The stored pasteboard items, exactly as they were copied.
    func payload(_ id: Int64) -> [PayloadItem]? {
        guard let uuid = uuid(of: id), let raw = try? Data(contentsOf: blobURL(uuid)),
              let plist = try? (raw as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? PropertyListDecoder().decode([PayloadItem].self, from: plist)
    }

    func uuid(of id: Int64) -> String? {
        var uuid: String?
        locked { db.run("SELECT uuid FROM item WHERE id = ?", [id]) { uuid = $0.text(0) } }
        return uuid
    }

    // MARK: capture

    /// A re-copy of something we already have: move it to the front (and back from trash / pinned-only). Returns its id.
    func bump(checksum: String, at date: Date = Date()) -> Int64? {
        locked {
            var id: Int64?
            db.run("SELECT id FROM item WHERE checksum = ?", [checksum]) { id = $0.int(0) }
            guard let id else { return nil }
            db.run("UPDATE item SET timestamp = ?, deleted_at = NULL WHERE id = ?", [date.timeIntervalSince1970, id])
            notify()
            return id
        }
    }

    struct NewItem {
        var kind: ItemKind
        var checksum: String
        var preview: Preview
        var searchText: String
        var payload: [PayloadItem]
        var appBundleID: String?
        var appName: String?
    }

    /// Inserts a new clip (or bumps it if the checksum already exists). Returns its id.
    @discardableResult
    func insert(_ n: NewItem, at date: Date = Date()) -> Int64? {
        if let id = bump(checksum: n.checksum, at: date) { return id }
        guard let plist = try? PropertyListEncoder.binary.encode(n.payload),
              let blob = try? (plist as NSData).compressed(using: .lzfse) as Data,
              let preview = try? PropertyListEncoder.binary.encode(n.preview) else { return nil }
        let uuid = UUID().uuidString
        do { try blob.write(to: blobURL(uuid), options: .atomic) } catch { log("blob write failed: \(error)"); return nil }
        return locked {
            db.exec("BEGIN IMMEDIATE")
            var appID: Int64?
            if let bid = n.appBundleID {
                db.run("INSERT INTO app (bundle_id, name) VALUES (?, ?) ON CONFLICT(bundle_id) DO UPDATE SET name = excluded.name",
                       [bid, n.appName ?? bid])
                db.run("SELECT id FROM app WHERE bundle_id = ?", [bid]) { appID = $0.int(0) }
            }
            let t = date.timeIntervalSince1970
            let ok = db.run("""
                INSERT INTO item (uuid, kind, checksum, preview, payload_bytes, timestamp, created_at, app_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, [uuid, n.kind.rawValue, n.checksum, preview, blob.count, t, t, appID]) == 1
            guard ok else { db.exec("ROLLBACK"); try? FileManager.default.removeItem(at: blobURL(uuid)); return nil }
            let id = db.lastID
            db.run("INSERT INTO item_fts (rowid, body, title, meta) VALUES (?, ?, '', ?)",
                   [id, String(n.searchText.prefix(100_000)), "\(n.appName ?? "") \(n.kind.label) \(n.preview.title ?? "")"])
            db.exec("COMMIT")
            notify()
            return id
        }
    }

    /// Re-runs the classifier on image and file clips (after the thumbnail size or the image-file rule changes).
    func reclassifyImages() {
        var ids: [Int64] = []
        locked {
            db.run("SELECT id FROM item WHERE kind IN (?, ?) AND deleted_at IS NULL", [ItemKind.image.rawValue, ItemKind.file.rawValue]) { ids.append($0.int(0)) }
        }
        for id in ids {
            guard let items = payload(id) else { continue }
            let r = Classifier.analyze(items)
            guard r.kind == .image, let data = try? PropertyListEncoder.binary.encode(Classifier.preview(r, items).0) else { continue }
            locked { _ = db.run("UPDATE item SET kind = ?, preview = ? WHERE id = ?", [r.kind.rawValue, data, id]) }
        }
        notify()
    }

    /// Late preview data (link title/image, file thumbnail).
    func updatePreview(_ id: Int64, _ change: (inout Preview) -> Void) {
        locked {
            var current: Preview?
            db.run("SELECT preview FROM item WHERE id = ?", [id]) { current = try? PropertyListDecoder().decode(Preview.self, from: $0.data(0) ?? Data()) }
            guard var p = current else { return }
            change(&p)
            guard let data = try? PropertyListEncoder.binary.encode(p) else { return }
            db.run("UPDATE item SET preview = ? WHERE id = ?", [data, id])
            if let title = p.title { db.run("UPDATE item_fts SET meta = meta || ' ' || ? WHERE rowid = ?", [title, id]) }
            notify()
        }
    }

    // MARK: editing

    private func each(_ ids: [Int64], _ sql: String, _ args: (Int64) -> [Any?]) {
        locked {
            db.exec("BEGIN IMMEDIATE")
            for id in ids { db.run(sql, args(id)) }
            db.exec("COMMIT")
            notify()
        }
    }

    /// Pasted or copied from the drawer: moves to the front of History.
    func touch(_ ids: [Int64], at date: Date = Date()) {
        each(ids, "UPDATE item SET timestamp = ? WHERE id = ?") { [date.timeIntervalSince1970, $0] }
    }

    func rename(_ id: Int64, to title: String?) {
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = t?.isEmpty == false ? t : nil
        each([id], "UPDATE item SET title = ? WHERE id = ?") { [value, $0] }
        locked { _ = db.run("UPDATE item_fts SET title = ? WHERE rowid = ?", [value ?? "", id]) }
    }

    /// Pins (or moves) clips to a board, newest pin on top. Idempotent.
    func pin(_ ids: [Int64], to board: Int64) {
        locked {
            var top: Int64 = 0
            db.run("SELECT COALESCE(MAX(pin_order), 0) FROM item WHERE pinboard_id = ?", [board]) { top = $0.int(0) }
            db.exec("BEGIN IMMEDIATE")
            for id in ids.reversed() {
                top += 1
                db.run("UPDATE item SET pinboard_id = ?, pin_order = ? WHERE id = ? AND pinboard_id IS NOT ?", [board, top, id, board])
            }
            db.exec("COMMIT")
            notify()
        }
    }

    /// Unpin never deletes: a pinned-only clip goes back into History.
    func unpin(_ ids: [Int64]) {
        each(ids, "UPDATE item SET pinboard_id = NULL, timestamp = COALESCE(timestamp, ?) WHERE id = ?") { [Date().timeIntervalSince1970, $0] }
    }

    /// `ids` top to bottom, as the pinboard should now show them.
    func reorder(board: Int64, _ ids: [Int64]) {
        let n = ids.count
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, n - $0) })
        each(ids, "UPDATE item SET pin_order = ? WHERE id = ? AND pinboard_id = ?") { [order[$0]!, $0, board] }
    }

    func delete(_ ids: [Int64]) { each(ids, "UPDATE item SET deleted_at = ? WHERE id = ?") { [Date().timeIntervalSince1970, $0] } }
    func restore(_ ids: [Int64]) { each(ids, "UPDATE item SET deleted_at = NULL WHERE id = ?") { [$0] } }

    // MARK: pinboards

    @discardableResult
    func createPinboard(name: String = "Untitled") -> Pinboard {
        locked {
            var count: Int64 = 0, pos: Int64 = 0
            db.run("SELECT COUNT(*), COALESCE(MAX(position), -1) + 1 FROM pinboard") { count = $0.int(0); pos = $0.int(1) }
            let rgb = Self.swatches[Int(count) % Self.swatches.count]
            db.run("INSERT INTO pinboard (name, color, position, created_at) VALUES (?, ?, ?, ?)", [name, rgb, pos, Date().timeIntervalSince1970])
            notify()
            return Pinboard(id: db.lastID, name: name, rgb: rgb)
        }
    }

    func renamePinboard(_ id: Int64, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        each([id], "UPDATE pinboard SET name = ? WHERE id = ?") { [n, $0] }
    }

    func recolorPinboard(_ id: Int64, rgb: Int) { each([id], "UPDATE pinboard SET color = ? WHERE id = ?") { [rgb, $0] } }

    /// Swaps a board with its neighbour (`by` = -1 up, +1 down).
    func movePinboard(_ id: Int64, by step: Int) {
        let boards = pinboards()
        guard let i = boards.firstIndex(where: { $0.id == id }), boards.indices.contains(i + step) else { return }
        var ids = boards.map(\.id)
        ids.swapAt(i, i + step)
        each(ids, "UPDATE pinboard SET position = ? WHERE id = ?") { [ids.firstIndex(of: $0)!, $0] }
    }

    /// Deletes the board and its pinned-only clips; clips still in History just lose the pin (once purged). Undo with `restorePinboard`.
    func deletePinboard(_ id: Int64) {
        let t = Date().timeIntervalSince1970
        locked {
            db.exec("BEGIN IMMEDIATE")
            db.run("UPDATE pinboard SET deleted_at = ? WHERE id = ?", [t, id])
            db.run("UPDATE item SET deleted_at = ? WHERE pinboard_id = ? AND timestamp IS NULL AND deleted_at IS NULL", [t, id])
            db.exec("COMMIT")
            notify()
        }
    }

    func restorePinboard(_ id: Int64) {
        locked {
            db.exec("BEGIN IMMEDIATE")
            db.run("UPDATE item SET deleted_at = NULL WHERE pinboard_id = ? AND deleted_at = (SELECT deleted_at FROM pinboard WHERE id = ?)", [id, id])
            db.run("UPDATE pinboard SET deleted_at = NULL WHERE id = ?", [id])
            db.exec("COMMIT")
            notify()
        }
    }

    // MARK: housekeeping

    /// Drops unpinned clips older than `cutoff`; pinned ones leave History but stay on their board.
    func trim(before cutoff: Date) {
        let t = cutoff.timeIntervalSince1970
        locked {
            hardDelete("timestamp < ? AND pinboard_id IS NULL", [t])
            db.run("UPDATE item SET timestamp = NULL WHERE timestamp < ? AND pinboard_id IS NOT NULL", [t])
            notify()
        }
    }

    /// Erase History: same as trimming everything.
    func eraseHistory() { trim(before: .distantFuture) }

    /// Permanently removes what was deleted before `cutoff` (past the point anyone would ⌘Z it).
    func purge(before cutoff: Date = .distantFuture) {
        let t = cutoff.timeIntervalSince1970
        locked {
            hardDelete("deleted_at < ?", [t])
            db.run("DELETE FROM pinboard WHERE deleted_at < ?", [t])
        }
    }

    private func hardDelete(_ whereSQL: String, _ args: [Any?]) {
        var gone: [(Int64, String)] = []
        db.run("SELECT id, uuid FROM item WHERE \(whereSQL)", args) { gone.append(($0.int(0), $0.text(1) ?? "")) }
        guard !gone.isEmpty else { return }
        db.exec("BEGIN IMMEDIATE")
        for (id, _) in gone {
            db.run("DELETE FROM item_fts WHERE rowid = ?", [id])
            db.run("DELETE FROM item WHERE id = ?", [id])
        }
        db.exec("COMMIT")
        for (_, uuid) in gone { try? FileManager.default.removeItem(at: blobURL(uuid)) }
    }
}

extension PropertyListEncoder {
    static var binary: PropertyListEncoder { let e = PropertyListEncoder(); e.outputFormat = .binary; return e }
}
