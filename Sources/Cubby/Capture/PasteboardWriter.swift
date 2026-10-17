import AppKit

/// Puts stored clips back on the pasteboard, and optionally types ⌘V into the app you were in.
enum PasteboardWriter {
    /// What a clip becomes as plain text (nil for images and unknown data).
    static func plainText(_ c: Clip, _ items: [PayloadItem]?) -> String? {
        switch c.kind {
        case .text: items.flatMap(Classifier.string) ?? c.text
        case .link, .color: c.text
        case .file: c.paths.joined(separator: "\n")
        case .image, .unknown: nil
        }
    }

    /// Writes `clips` (several text clips join into one with newlines). Returns false if nothing could be written.
    @discardableResult
    static func write(_ clips: [Clip], plain: Bool, store: Store = .shared, pasteboard pb: NSPasteboard = .general) -> Bool {
        let payloads = clips.map { store.payload($0.id) }
        let texts = zip(clips, payloads).map { plainText($0, $1) }
        let allText = clips.allSatisfy { [.text, .link, .color].contains($0.kind) }
        var out: [NSPasteboardItem] = []
        if (plain || (allText && clips.count > 1)), texts.contains(where: { $0 != nil }) {
            let item = NSPasteboardItem()
            item.setString(texts.compactMap { $0 }.joined(separator: "\n"), forType: .string)
            out = [item]
        } else {
            out = payloads.compactMap { $0 }.flatMap { $0.map(\.pasteboardItem) }
        }
        guard !out.isEmpty else { return false }
        pb.clearContents()
        pb.writeObjects(out)
        if pb == .general { ClipboardWatcher.shared.ignoreCurrent() }
        store.touch(clips.map(\.id))
        return true
    }

    /// Plain text straight onto the pasteboard (e.g. a link's original, uncleaned form).
    static func write(text: String, pasteboard pb: NSPasteboard = .general) {
        pb.clearContents()
        pb.setString(text, forType: .string)
        if pb == .general { ClipboardWatcher.shared.ignoreCurrent() }
    }

    static var canDirectPaste: Bool { AXIsProcessTrusted() }

    static func askForDirectPaste() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    /// ⌘V into whatever app is frontmost (the drawer never took that away).
    static func typeCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }
}
