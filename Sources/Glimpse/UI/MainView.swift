import SwiftUI

/// The Kooha window: capture mode, audio/pointer toggles, Record button,
/// with countdown / recording / flushing pages swapped in via crossfade.
struct MainView: View {
    static let height: CGFloat = 300
    /// The (transparent) title bar sits above the content, so only a little breathing room.
    private let titleBarInset: CGFloat = 4

    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var controller = RecordingController.shared

    var body: some View {
        ZStack {
            switch controller.state {
            case .idle, .selectingSource:
                mainPage.transition(.opacity)
            case .delayed(let left):
                delayPage(left).transition(.opacity)
            case .recording(let duration):
                recordingPage(duration).transition(.opacity)
            case .flushing:
                flushingPage.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controller.state)
        .frame(width: 250, height: Self.height)
        .alert(L("alert.capture_failed"), isPresented: Binding(
            get: { controller.lastError != nil },
            set: { if !$0 { controller.lastError = nil } })
        ) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(controller.lastError ?? "")
        }
    }

    // MARK: Main page

    private var mainPage: some View {
        VStack(spacing: 12) {
            header
            HStack(spacing: 0) {
                ForEach(CaptureMode.allCases) { mode in
                    Button { settings.captureMode = mode } label: {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 30, weight: .regular))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ToggleTileStyle(isOn: settings.captureMode == mode))
                    .help(mode.help)
                    .accessibilityLabel(mode.title)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
            .frame(maxHeight: .infinity)

            HStack(spacing: 12) {
                smallToggle($settings.recordDesktopAudio, on: "speaker.wave.2.fill", off: "speaker.slash.fill",
                            onHelp: L("toggle.desktop_audio.disable"), offHelp: L("toggle.desktop_audio.enable"))
                smallToggle($settings.recordMicrophone, on: "mic.fill", off: "mic.slash.fill",
                            onHelp: L("toggle.microphone.disable"), offHelp: L("toggle.microphone.enable"))
                smallToggle($settings.showPointer, on: "cursorarrow", off: "cursorarrow.slash",
                            onHelp: L("toggle.pointer.hide"), offHelp: L("toggle.pointer.show"))
            }
            .frame(height: 54)

            Button {
                controller.toggleRecord()
            } label: {
                Text(controller.state == .selectingSource ? L("main.cancel") : L("main.record"))
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.state == .selectingSource ? .gray : .accentColor)
            .keyboardShortcut(.defaultAction)
            .help(L(controller.state == .selectingSource ? "main.cancel" : "main.start_recording.help"))
            .accessibilityLabel(controller.state == .selectingSource ? L("main.cancel") : L("main.record"))
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .padding(.top, titleBarInset)
    }

    private var header: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(settings.captureMode.title).font(.system(size: 15, weight: .bold))
                Text(L("main.profile", settings.profile.name, settings.framerate))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            // The buttons sit on the right of the same ZStack; without a width the
            // longer profile names ("QuickTime (H.264) • 60 FPS") run underneath them.
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: 124)
            HStack {
                Spacer()
                Button {
                    ScreenshotController.shared.start()
                } label: {
                    Image(systemName: "camera.viewfinder").font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                // start() refuses while a recording owns the machine, and a control
                // that silently does nothing is worse than one that looks unavailable.
                .disabled(controller.state.isBusy)
                .help(L("main.screenshot.help", settings.screenshotHotKey.displayString))
                .accessibilityLabel(L("menu.take_screenshot"))

                Menu {
                    Button(L("menu.open_recordings")) { SaveDestination.openInFinder(settings.recordingsFolder) }
                    Button(L("menu.open_screenshots")) { SaveDestination.openInFinder(settings.screenshotsFolder) }
                    Divider()
                    Button(L("menu.preferences")) { PreferencesWindowController.shared.show() }
                    Button(L("menu.about")) { NSApp.orderFrontStandardAboutPanel(nil) }
                    Divider()
                    Button(L("menu.quit")) { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "line.3.horizontal").font(.system(size: 14, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("menu.main"))
                .accessibilityLabel(L("menu.main"))
            }
        }
        .frame(height: 34)
    }

    /// Only ever rendered on the idle page, so there is no live-recording state to
    /// gate here — that gate lives on the HUD, which is what is on screen instead.
    private func smallToggle(_ binding: Binding<Bool>, on: String, off: String,
                             onHelp: String, offHelp: String) -> some View {
        Button { binding.wrappedValue.toggle() } label: {
            Image(systemName: binding.wrappedValue ? on : off)
                .font(.system(size: 18, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToggleTileStyle(isOn: binding.wrappedValue, cornerRadius: 10))
        .help(binding.wrappedValue ? onHelp : offHelp)
        .accessibilityLabel(binding.wrappedValue ? onHelp : offHelp)
    }

    // MARK: Other pages

    private func delayPage(_ left: Int) -> some View {
        VStack {
            Spacer()
            Text(L("main.recording_in")).font(.system(size: 17, weight: .bold))
            Text("\(left)").font(.system(size: 64, weight: .light, design: .rounded)).monospacedDigit()
            Spacer()
            Button(L("main.cancel")) { controller.cancel() }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                .frame(maxWidth: .infinity)
                .keyboardShortcut(.cancelAction)
        }
        .padding(18)
        .padding(.top, titleBarInset)
    }

    private func recordingPage(_ duration: TimeInterval) -> some View {
        VStack {
            Spacer()
            Text(L(controller.isPaused ? "recording.paused" : "main.recording"))
                .font(.system(size: 17, weight: .bold))
            Text(formatDuration(duration))
                .font(.system(size: 54, weight: .light, design: .rounded)).monospacedDigit()
                .foregroundStyle(controller.isPaused ? Color.secondary : Color.red)
                .minimumScaleFactor(0.6).lineLimit(1)
            Spacer()
            HStack(spacing: 10) {
                // Icon-only: "Resume" is a long word in several of the shipped languages
                // and would squeeze Stop out of a 250pt window.
                Button {
                    controller.togglePause()
                } label: {
                    Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 30)
                }
                .buttonStyle(.bordered)
                .help(L(controller.isPaused ? "recording.resume" : "recording.pause"))
                .accessibilityLabel(L(controller.isPaused ? "recording.resume" : "recording.pause"))

                Button {
                    Task { await controller.stop() }
                } label: {
                    Text(L("main.stop")).font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 30)
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .keyboardShortcut(.defaultAction)
                .help(L("main.stop_recording.help"))
                .accessibilityLabel(L("main.stop"))
            }
        }
        .padding(18)
        .padding(.top, titleBarInset)
    }

    private var flushingPage: some View {
        VStack(spacing: 18) {
            Spacer()
            Text(L("main.flushing")).font(.system(size: 17, weight: .bold))
            ProgressView().controlSize(.regular)
            Spacer()
        }
        .padding(18)
        .padding(.top, titleBarInset)
    }
}

/// Flat toggle tile, the equivalent of GTK's linked toggle buttons.
struct ToggleTileStyle: ButtonStyle {
    var isOn: Bool
    var cornerRadius: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isOn ? Color.primary : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isOn ? Color.accentColor.opacity(configuration.isPressed ? 0.30 : 0.20)
                               : Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06))
            )
            // The two capture-mode tiles carry different symbols, so the fill was the
            // only state cue — and an opacity difference is not one under Increase
            // Contrast. The border is.
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(isOn ? Color.accentColor : .clear, lineWidth: 1.5)
            )
            .animation(.easeOut(duration: 0.15), value: isOn)
    }
}
