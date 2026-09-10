import Carbon
import Testing
@testable import Glimpse

@Suite("KeyCombo")
struct KeyComboTests {
    @Test func encodedRoundTrip() {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: [.control, .shift])
        #expect(KeyCombo(encoded: combo.encoded) == combo)
    }

    /// Caps lock, fn and the "numeric pad" flag must not end up in a stored shortcut,
    /// or the same physical key stops matching the registered hot key.
    @Test func initKeepsOnlyRealModifiers() {
        let combo = KeyCombo(keyCode: 1, modifiers: [.command, .capsLock, .function, .numericPad])
        #expect(combo.modifiers == [.command])
    }

    @Test(arguments: [nil, "", "42", "abc:1", "42:xyz"])
    func malformedEncodingIsRejected(_ encoded: String?) {
        #expect(KeyCombo(encoded: encoded) == nil)
    }

    /// macOS always renders modifiers in this order, whatever order they were pressed in.
    @Test func displayStringUsesAppleModifierOrder() {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: [.command, .shift, .option, .control])
        #expect(combo.displayString == "⌃⌥⇧⌘S")
    }

    @Test func carbonModifiersMapEveryFlag() {
        #expect(KeyCombo(keyCode: 0, modifiers: [.command]).carbonModifiers == UInt32(cmdKey))
        #expect(KeyCombo(keyCode: 0, modifiers: [.shift]).carbonModifiers == UInt32(shiftKey))
        #expect(KeyCombo(keyCode: 0, modifiers: [.control]).carbonModifiers == UInt32(controlKey))
        #expect(KeyCombo(keyCode: 0, modifiers: [.option]).carbonModifiers == UInt32(optionKey))
        #expect(KeyCombo(keyCode: 0, modifiers: []).carbonModifiers == 0)
    }

    /// The regression that crashed the app on every keypress in the shortcut
    /// recorder: the codes are neither contiguous nor ordered, so `kVK_F1...kVK_F20`
    /// was the invalid range 122...90. Touching the set is what catches a return to
    /// a range — that traps while this static initialises, so the test cannot pass.
    @Test func functionKeyCodesAreAnEnumeratedSet() {
        #expect(kVK_F1 > kVK_F20, "if this ever became ordered, the range would be legal again")
        #expect(KeyCombo.functionKeyCodes.count == 20)
        #expect(KeyCombo.functionKeyCodes.contains(kVK_F1))
        #expect(KeyCombo.functionKeyCodes.contains(kVK_F20))
        // These four sit inside 90...122 and are not function keys, so they are what
        // a range would wrongly sweep in. kVK_ANSI_S is 1 and would prove nothing.
        #expect(!KeyCombo.functionKeyCodes.contains(kVK_Help))
        #expect(!KeyCombo.functionKeyCodes.contains(kVK_Home))
        #expect(!KeyCombo.functionKeyCodes.contains(kVK_PageUp))
        #expect(!KeyCombo.functionKeyCodes.contains(kVK_End))
    }

    @Test func functionKeysRender() {
        #expect(KeyCombo(keyCode: UInt32(kVK_F5), modifiers: []).displayString == "F5")
        // F13 sits among the navigation codes and is the one most likely to fall out
        // of the name table and be translated into something meaningless.
        #expect(KeyCombo(keyCode: UInt32(kVK_F13), modifiers: []).displayString == "F13")
        #expect(KeyCombo(keyCode: UInt32(kVK_F20), modifiers: []).displayString == "F20")
    }

    /// A stored key code above UInt16 used to trap the process inside keyName's
    /// narrowing conversion — on launch, before any window existed to fix it from.
    @Test(arguments: ["65536:262144", "70000:262144", "4294967295:262144"])
    func outOfRangeKeyCodeIsRejected(_ encoded: String) {
        #expect(KeyCombo(encoded: encoded) == nil)
    }

    /// Carbon happily registers a bare key or a shift-only combination, and the
    /// shortcut then swallows that key in every application on the Mac.
    @Test func bareAndShiftOnlyCombinationsAreNotAssignable() {
        #expect(!KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: []).isAssignable)
        #expect(!KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: [.shift]).isAssignable)
        #expect(KeyCombo(encoded: "15:0") == nil)
        #expect(KeyCombo(encoded: "1:131072") == nil)
    }

    @Test func realShortcutsAndBareFunctionKeysAreAssignable() {
        #expect(KeyCombo.defaultScreenshot.isAssignable)
        #expect(KeyCombo.defaultRecord.isAssignable)
        #expect(KeyCombo(keyCode: UInt32(kVK_F5), modifiers: []).isAssignable)
        #expect(KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: [.command]).isAssignable)
        #expect(KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: [.option]).isAssignable)
    }

    @Test func defaultShortcutsDiffer() {
        #expect(KeyCombo.defaultScreenshot != KeyCombo.defaultRecord)
    }
}
