import Carbon.HIToolbox
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var settings = AppSettings.shared
    /// Set once the picker changes, so the restart button only appears when it matters.
    @State private var languageChanged = false

    var body: some View {
        Form {
            Section {
                Stepper(value: $settings.recordDelay, in: 0...30) {
                    LabeledContent(L("prefs.delay_seconds")) { Text("\(settings.recordDelay)") }
                }
                folderRow(L("prefs.recordings_folder"), url: $settings.recordingsFolder)
                folderRow(L("prefs.screenshots_folder"), url: $settings.screenshotsFolder)
                Toggle(L("prefs.show_preview"), isOn: $settings.showPreviewAfterCapture)
            } header: {
                Text(L("prefs.general"))
            }

            Section {
                Toggle(L("prefs.ask_where_to_save"), isOn: $settings.askWhereToSave)
            } footer: {
                Text(L("prefs.ask_where_to_save.footer"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker(L("prefs.language.picker"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: settings.language) { languageChanged = true }
                if languageChanged {
                    // Standalone buttons in a Form row come out unlabelled in the
                    // accessibility tree, so name it explicitly for VoiceOver.
                    Button(L("prefs.language.restart")) { Permissions.relaunch() }
                        .accessibilityLabel(L("prefs.language.restart"))
                }
            } header: {
                Text(L("prefs.language"))
            } footer: {
                Text(L("prefs.language.footer")).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(L("prefs.echo_cancellation"), isOn: $settings.microphoneEchoCancellation)
            } header: {
                Text(L("prefs.audio"))
            } footer: {
                Text(L("prefs.echo_cancellation.footer"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("prefs.video")) {
                Picker(L("prefs.format"), selection: $settings.profileID) {
                    ForEach(RecordingProfile.all) { Text($0.name).tag($0.id) }
                }
                Picker(L("prefs.frame_rate"), selection: $settings.framerate) {
                    ForEach(RecordingProfile.framerates, id: \.self) { fps in
                        if fps > settings.profile.suggestedMaxFPS {
                            Label(L("prefs.fps", fps), systemImage: "exclamationmark.triangle").tag(fps)
                        } else {
                            Text(L("prefs.fps", fps)).tag(fps)
                        }
                    }
                }
                Picker(L("prefs.quality"), selection: $settings.quality) {
                    ForEach(RecordingQuality.allCases) { Text($0.displayName).tag($0) }
                }
                Text(L("prefs.quality.footer"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("prefs.screenshots")) {
                Picker(L("prefs.format"), selection: $settings.screenshotFormat) {
                    ForEach(ScreenshotFormat.allCases) { Text($0.title).tag($0) }
                }
                Toggle(L("prefs.copy_clipboard"), isOn: $settings.screenshotCopiesToClipboard)
                Toggle(L("prefs.include_pointer"), isOn: $settings.screenshotShowsPointer)
                Toggle(L("prefs.shutter_sound"), isOn: $settings.screenshotPlaysSound)
            }

            Section {
                ShortcutRecorder(title: L("prefs.shortcut.screenshot"), id: 1,
                                 combo: $settings.screenshotHotKey, other: settings.recordHotKey)
                ShortcutRecorder(title: L("prefs.shortcut.record"), id: 2,
                                 combo: $settings.recordHotKey, other: settings.screenshotHotKey)
            } header: {
                Text(L("prefs.shortcuts"))
            } footer: {
                Text(L("prefs.shortcuts.footer"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 480, maxWidth: .infinity,
               minHeight: 400, idealHeight: 700, maxHeight: .infinity)
    }

    private func folderRow(_ title: String, url: Binding<URL>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(url.wrappedValue.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button(L("prefs.choose")) {
                    let panel = SaveDestination.folderChooser()
                    panel.directoryURL = url.wrappedValue
                    if SaveDestination.runModal(panel) == .OK, let picked = panel.url {
                        url.wrappedValue = picked
                    }
                }
            }
        }
    }
}

/// Click, press a key combination, done. Escape cancels.
struct ShortcutRecorder: View {
    let title: String
    /// Matches the id this shortcut is registered under, so a failed registration
    /// can be shown on the right row.
    let id: UInt32
    @Binding var combo: KeyCombo
    /// The other shortcut. Carbon refuses a duplicate registration, which would kill
    /// one of the two with no feedback at all, so the same combination is rejected.
    let other: KeyCombo
    @ObservedObject private var hotKeys = HotKeyCenter.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var closeObserver: Any?
    /// Shown when a keypress is refused, so the button does not just sit there
    /// saying "Press keys…" while apparently ignoring the user.
    @State private var needsModifier = false

    /// Only one recorder may be armed at a time: two local monitors would both
    /// swallow the same key press. The id records whose hook is installed, so one
    /// recorder stopping cannot clear another one's.
    @MainActor private static var armedID: UInt32?
    @MainActor private static var disarmOther: (() -> Void)?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                if needsModifier {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .help(L("prefs.shortcut.needs_modifier"))
                        .accessibilityLabel(L("prefs.shortcut.needs_modifier"))
                }
                if hotKeys.unavailable.contains(id) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(L("prefs.shortcut.unavailable"))
                        .accessibilityLabel(L("prefs.shortcut.unavailable"))
                }
                Button {
                    recording ? stop() : start()
                } label: {
                    Text(recording ? (needsModifier ? L("prefs.shortcut.needs_modifier") : L("prefs.shortcut.press_keys"))
                           : combo.displayString)
                        .font(.system(.body, design: .rounded).monospacedDigit())
                        .frame(minWidth: 90)
                }
                .buttonStyle(.bordered)
                .tint(recording ? .accentColor : nil)
                .help(L("prefs.shortcut.change"))
                .accessibilityLabel(L("prefs.shortcut.change"))
                .accessibilityValue(combo.displayString)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        Self.disarmOther?()
        stop()
        Self.armedID = id
        Self.disarmOther = { stop() }
        recording = true
        HotKeyCenter.shared.suspend()
        // The Preferences window is only ordered out, never closed, so onDisappear is
        // not guaranteed; without this the monitor survives and swallows every key.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
                // Only the window this recorder lives in disarms it. Excluding
                // panels was not enough: a SwiftUI Picker's popup is an NSWindow,
                // so opening and closing one silently cancelled the recording.
                MainActor.assumeIsolated {
                    guard let closing = note.object as? NSWindow,
                          closing === PreferencesWindowController.shared.window else { return }
                    stop()
                }
            }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])
            let candidate = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods)
            // Shift alone is not a modifier for this purpose: ⇧S registers happily and
            // then eats every capital S typed anywhere on the Mac, including the ones
            // needed to record a replacement. Say so rather than swallowing the key
            // and leaving the button looking broken.
            guard candidate.isAssignable else {
                needsModifier = true
                return nil
            }
            needsModifier = false
            // Refuse rather than accept and silently lose the other shortcut.
            guard candidate != other else { stop(); return nil }
            combo = candidate
            stop()
            return nil
        }
    }

    private func stop() {
        if recording { HotKeyCenter.shared.resume() }
        recording = false
        needsModifier = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        if Self.armedID == id {
            Self.armedID = nil
            Self.disarmOther = nil
        }
    }
}
