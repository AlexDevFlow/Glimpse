import AppKit
import Combine
import SwiftUI

/// Floating, non-activating control strip shown while recording (and during the
/// countdown). It is excluded from the capture, can be dragged anywhere, and offers
/// Stop plus the live audio / microphone / pointer switches.
@MainActor
final class RecordingHUD {
    static let shared = RecordingHUD()
    private var panel: NSPanel?
    private var layoutObserver: AnyCancellable?
    /// Guards the fade-out completion: a recording started inside the 150ms fade
    /// would otherwise have its freshly shown HUD ordered out again.
    private var wantsVisible = false

    private init() {}

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            // Excluded from any screen capture, ours or another app's.
            p.sharingType = .none
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let host = NSHostingView(rootView: RecordingHUDView())
            host.sizingOptions = [.intrinsicContentSize]
            p.contentView = host
            panel = p
        }
        // Reposition on every show. The panel is cached for the process lifetime, so
        // otherwise every later recording inherits the display the first one used.
        if let panel, let host = panel.contentView as? NSHostingView<RecordingHUDView>,
           let screen = NSScreen.main ?? NSScreen.screens.first {
            let size = host.fittingSize
            panel.setFrame(CGRect(x: screen.frame.midX - size.width / 2,
                                  y: screen.visibleFrame.maxY - size.height - 12,
                                  width: size.width, height: size.height), display: true)
        }
        // The countdown page is far narrower than the recording page, and the panel
        // is created once. Without this, a recording started with a delay sizes the
        // HUD for the countdown and leaves Stop outside the window — for the rest of
        // the session, since the panel is cached.
        if layoutObserver == nil {
            layoutObserver = RecordingController.shared.$state
                .sink { [weak self] _ in self?.scheduleRelayout() }
        }
        wantsVisible = true
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel?.animator().alphaValue = 1
        }
    }

    func hide() {
        wantsVisible = false
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            if !self.wantsVisible { panel.orderOut(nil) }
        })
    }

    /// The page swap is animated, so the size right after a state change still
    /// reports the outgoing page. Measure now and again once the animation is done.
    private func scheduleRelayout() {
        DispatchQueue.main.async { [weak self] in self?.relayout() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.relayout() }
    }

    /// Resizes the panel to whatever the current page needs, keeping it anchored by
    /// its top edge and centre so it does not jump under the pointer, and on screen.
    private func relayout() {
        guard wantsVisible, let panel,
              let host = panel.contentView as? NSHostingView<RecordingHUDView> else { return }
        let size = host.fittingSize
        guard size.width > 1, size.height > 1,
              abs(size.width - panel.frame.width) > 0.5 || abs(size.height - panel.frame.height) > 0.5
        else { return }
        var origin = CGPoint(x: panel.frame.midX - size.width / 2, y: panel.frame.maxY - size.height)
        // Growing about the centre can push half the panel, Stop included, off screen.
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

private struct RecordingHUDView: View {
    @ObservedObject var controller = RecordingController.shared
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 10) {
            switch controller.state {
            case .delayed(let left):
                Text(L("hud.recording_in", left))
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    .frame(minWidth: 96)
                Button { controller.cancel() } label: {
                    Text(L("hud.cancel")).font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityLabel(L("hud.cancel"))
            case .flushing:
                ProgressView().controlSize(.small)
                Text(L("hud.saving")).font(.system(size: 13, weight: .semibold))
                    .frame(minWidth: 96)
            default:
                HStack(spacing: 6) {
                    // Pulses with the timer tick rather than a continuous animation.
                    Circle().fill(controller.isPaused ? Color.secondary : Color.red)
                        .frame(width: 9, height: 9)
                        .opacity(controller.isPaused || Int(durationValue) % 2 == 0 ? 1 : 0.35)
                        .animation(.easeInOut(duration: 0.4), value: Int(durationValue))
                    Text(formatDuration(durationValue))
                        .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .frame(minWidth: 64, alignment: .leading)

                Divider().frame(height: 20)

                RecordingToggles(settings: settings, iconSize: 14,
                                 microphoneEnabled: controller.canToggleMicrophoneLive)

                Divider().frame(height: 20)

                Button {
                    controller.togglePause()
                } label: {
                    Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help(L(controller.isPaused ? "recording.resume" : "recording.pause"))
                .accessibilityLabel(L(controller.isPaused ? "recording.resume" : "recording.pause"))

                Button {
                    Task { await controller.stop() }
                } label: {
                    Label(L("hud.stop"), systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                .help(L("hud.stop.help", settings.recordHotKey.displayString))
                .accessibilityLabel(L("hud.stop"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.14)))
        .fixedSize()
        .animation(.snappy(duration: 0.25), value: controller.state)
    }

    private var durationValue: TimeInterval {
        if case .recording(let d) = controller.state { return d }
        return 0
    }
}
