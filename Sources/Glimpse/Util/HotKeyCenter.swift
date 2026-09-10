import AppKit
import Carbon

/// Global hotkeys via Carbon's RegisterEventHotKey. Needs no Accessibility permission.
@MainActor
final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()

    /// Ids whose combination could not be installed — normally because another app
    /// already owns it. Preferences shows a warning instead of letting the shortcut
    /// die in silence.
    @Published private(set) var unavailable: Set<UInt32> = []

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var combos: [UInt32: KeyCombo] = [:]
    private var suspended = false
    private var installed = false
    private static let signature: OSType = 0x47_4C_4D_50 // "GLMP"

    private init() {}

    private func installIfNeeded() {
        guard !installed else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let key = id.id
            Task { @MainActor in HotKeyCenter.shared.handlers[key]?() }
            return noErr
        }, 1, &spec, nil, nil)
        // Only mark it installed if it really is: otherwise every hot key registers
        // at the Carbon level and no handler ever fires, permanently and silently.
        installed = status == noErr
        if !installed { Log.write("HotKeyCenter: InstallEventHandler failed (\(status))") }
    }

    @discardableResult
    func register(id: UInt32, combo: KeyCombo, handler: @escaping () -> Void) -> Bool {
        installIfNeeded()
        releaseRef(id: id)
        // Recorded before the attempt, not after it: resume() rebuilds from these,
        // and a shortcut the user chose must survive a registration that failed.
        combos[id] = combo
        handlers[id] = handler
        // Without the handler the Carbon registration below still succeeds and no
        // hot key ever fires; that has to show up as unavailable too.
        guard installed else {
            unavailable.insert(id)
            return false
        }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
            unavailable.remove(id)
            return true
        }
        unavailable.insert(id)
        Log.write("HotKeyCenter: could not register \(combo.displayString) for id \(id) (status \(status))")
        return false
    }

    func unregister(id: UInt32) {
        releaseRef(id: id)
        handlers[id] = nil
        combos[id] = nil
    }

    private func releaseRef(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }

    /// Carbon consumes a registered hot key before it ever becomes an NSEvent, so
    /// while the shortcut recorder is listening the app's own shortcuts would fire
    /// instead of being recorded — pressing ⌃⇧R to reassign it started a recording.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        for (id, combo) in combos {
            guard let handler = handlers[id] else { continue }
            register(id: id, combo: combo, handler: handler)
        }
    }

    /// True while the shortcut recorder owns the keyboard.
    var isSuspended: Bool { suspended }
}
