import Combine
import SwiftUI

@main
struct GlimpseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var controller = RecordingController.shared
    @ObservedObject private var screenshots = ScreenshotController.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra {
            Button("\(L("menu.take_screenshot"))  \(settings.screenshotHotKey.displayString)") {
                ScreenshotController.shared.start()
            }
            .disabled(controller.state.isBusy)

            Button(recordItemTitle) {
                controller.toggleRecord()
            }
            // toggleRecord refuses while a capture flow owns the machine; without
            // this the item stayed enabled and simply did nothing when pressed.
            .disabled(controller.state == .flushing || screenshots.isBusy)

            if controller.state.isRecording {
                Button(L(controller.isPaused ? "menu.resume_recording" : "menu.pause_recording")) {
                    controller.togglePause()
                }
                // The same three switches the HUD carries. The HUD is a borderless
                // non-activating panel, so it takes no keyboard focus and VoiceOver
                // cannot reach it — and while recording the main window is hidden, so
                // this menu was the only surface left. Making the panel key-capable
                // would mean activating the app, which changes focus in whatever is
                // being recorded.
                Button(L(settings.recordDesktopAudio ? "toggle.desktop_audio.disable"
                                                     : "toggle.desktop_audio.enable")) {
                    settings.recordDesktopAudio.toggle()
                }
                Button(L(settings.recordMicrophone ? "toggle.microphone.disable"
                                                   : "toggle.microphone.enable")) {
                    settings.recordMicrophone.toggle()
                }
                .disabled(!controller.canToggleMicrophoneLive)
                Button(L(settings.showPointer ? "toggle.pointer.hide" : "toggle.pointer.show")) {
                    settings.showPointer.toggle()
                }
            }

            Divider()

            Button(L("menu.open_app")) { MainWindowController.shared.show() }
            Button(L("menu.open_recordings")) { SaveDestination.openInFinder(settings.recordingsFolder) }
            Button(L("menu.open_screenshots")) { SaveDestination.openInFinder(settings.screenshotsFolder) }
            Button(L("menu.preferences")) { PreferencesWindowController.shared.show() }

            Divider()

            Button(L("menu.quit_app")) { NSApp.terminate(nil) }
        } label: {
            menuBarLabel
                .accessibilityLabel(L("window.main.title"))
        }
        .menuBarExtraStyle(.menu)
    }

    private var recordItemTitle: String {
        switch controller.state {
        case .recording: return "\(L("menu.stop_recording"))  \(settings.recordHotKey.displayString)"
        case .delayed, .selectingSource: return L("menu.cancel_recording")
        default: return "\(L("menu.record_screen"))  \(settings.recordHotKey.displayString)"
        }
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        if let left = screenshots.countdown {
            Label("\(left)", systemImage: "timer")
        } else {
            recordingLabel
        }
    }

    @ViewBuilder
    private var recordingLabel: some View {
        switch controller.state {
        case .recording(let d):
            Label(formatDuration(d), systemImage: controller.isPaused ? "pause.circle.fill" : "record.circle.fill")
                .labelStyle(.titleAndIcon)
        case .delayed(let left):
            Label("\(left)", systemImage: "timer")
        case .flushing:
            Image(systemName: "arrow.down.circle")
        default:
            Image(systemName: "rectangle.dashed.badge.record")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerHotKeys()

        let settings = AppSettings.shared
        // receive(on:) defers to the next main-queue turn: @Published emits in
        // willSet, so reading the property in the sink still gave the old shortcut
        // and the new one never registered until the next launch.
        settings.$screenshotHotKey.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.registerHotKeys() }.store(in: &cancellables)
        settings.$recordHotKey.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.registerHotKeys() }.store(in: &cancellables)

        MainWindowController.shared.show()
    }

    /// Double-clicking the app (or its Dock tile) while it is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controller = RecordingController.shared
        controller.isTerminating = true
        // A screenshot in flight counts as pending work. It used to be invisible
        // here — hasPendingWork tracks recording flushes only — so quitting while
        // its Save panel was up killed the process with the capture unwritten.
        // Tearing the panel down instead (abortModal) does not help: it is
        // asynchronous, so a process that exits on the next line never pumps the
        // loop that would act on it, and it discards the user's work if the quit is
        // then abandoned. Wait for it instead.
        let shots = ScreenshotController.shared
        guard controller.state.isBusy || controller.hasPendingWork || shots.isBusy else {
            return .terminateNow
        }
        // Finish the file cleanly instead of leaving a truncated recording behind.
        Task { @MainActor in
            if controller.state.isRecording {
                await controller.stop()
            } else {
                controller.cancel()
            }
            // Always: stop() returns immediately if another task already owns the
            // flush, and replying before it finishes leaves the file without its
            // moov atom.
            await controller.waitWhileFlushing()
            await shots.waitWhileBusy()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func registerHotKeys() {
        let settings = AppSettings.shared
        HotKeyCenter.shared.register(id: 1, combo: settings.screenshotHotKey) {
            if SaveDestination.isPresenting || Permissions.isPresenting { return }
            ScreenshotController.shared.start()
        }
        HotKeyCenter.shared.register(id: 2, combo: settings.recordHotKey) {
            if CaptureOverlay.shared.isActive || SaveDestination.isPresenting
                || Permissions.isPresenting { return }
            RecordingController.shared.toggleRecord()
        }
    }
}
