import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey (no Accessibility permission needed).
final class Hotkeys {
    static let shared = Hotkeys()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            Hotkeys.shared.handlers[id.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    private var nextID: UInt32 = 0

    /// Drops every registration (Settings re-registers after a shortcut changes, and pauses them while recording).
    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    func register(keyCode: UInt32, modifiers: UInt32, _ handler: @escaping () -> Void) {
        nextID += 1
        let id = nextID
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4355_4259), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { log("hotkey register failed (\(status))"); return }
        refs.append(ref)
        handlers[id] = handler
    }
}
