import AppKit
import Carbon

/// A keyboard shortcut (virtual key code + modifier flags), storable as a string.
struct KeyCombo: Equatable, Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(keyCode); hasher.combine(modifiers.rawValue) }
    static func == (a: KeyCombo, b: KeyCombo) -> Bool { a.keyCode == b.keyCode && a.modifiers.rawValue == b.modifiers.rawValue }

    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags

    /// The F-key virtual codes. They are neither contiguous nor ordered — kVK_F1 is
    /// 122 and kVK_F20 is 90 — so writing them as a range traps at first use.
    static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    static let defaultScreenshot = KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: [.control, .shift])
    static let defaultRecord = KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: [.control, .shift])

    var encoded: String { "\(keyCode):\(modifiers.rawValue)" }

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .shift, .control, .option])
    }

    /// Virtual key codes are a byte in practice — the largest kVK_ constant is 126 —
    /// and `keyName(for:)` narrows to UInt16. A hand-edited or corrupted preference
    /// holding anything larger used to trap the process on launch, before any window
    /// existed to change it back from.
    static let maxKeyCode: UInt32 = 127

    /// macOS will not let you assign a bare key or a shift-only combination, and for
    /// good reason: Carbon accepts both, and the shortcut then swallows that key in
    /// every application on the Mac. Function keys are the recognised exception.
    var isAssignable: Bool {
        guard keyCode <= Self.maxKeyCode else { return false }
        if Self.functionKeyCodes.contains(Int(keyCode)) { return true }
        return !modifiers.intersection([.command, .control, .option]).isEmpty
    }

    init?(encoded: String?) {
        guard let encoded, let sep = encoded.firstIndex(of: ":"),
              let code = UInt32(encoded[..<sep]),
              let mods = UInt(encoded[encoded.index(after: sep)...]) else { return nil }
        self.init(keyCode: code, modifiers: NSEvent.ModifierFlags(rawValue: mods))
        // A stored combination that the recorder would refuse is refused here too,
        // so the caller falls back to the default instead of installing it.
        guard isAssignable else { return nil }
    }

    /// Carbon modifier mask for RegisterEventHotKey.
    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        return m
    }

    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + KeyCombo.keyName(for: keyCode)
    }

    static func keyName(for keyCode: UInt32) -> String {
        let special: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: L("key.space"), kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
            kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        ]
        if let s = special[Int(keyCode)] { return s }

        // Translate through the current keyboard layout.
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "?"
        }
        // Some input sources return something other than a CFData for this key, and
        // reading it as one is undefined behaviour.
        let property = Unmanaged<CFTypeRef>.fromOpaque(layoutData).takeUnretainedValue()
        guard CFGetTypeID(property) == CFDataGetTypeID() else { return "?" }
        let data = unsafeBitCast(layoutData, to: CFData.self)
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
            guard let base = ptr.baseAddress else { return OSStatus(paramErr) }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

private extension CFData {
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        let ptr = CFDataGetBytePtr(self)
        let len = CFDataGetLength(self)
        return try body(UnsafeRawBufferPointer(start: ptr, count: len))
    }
}
