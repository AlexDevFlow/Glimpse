import AppKit
import SwiftUI

/// Small floating card in the bottom-right corner shown after a capture,
/// in the spirit of macOS's screenshot thumbnail but with explicit actions.
@MainActor
final class CapturePreviewPanel {
    static let shared = CapturePreviewPanel()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(image: NSImage?, title: String, subtitle: String, fileURL: URL) {
        dismiss()
        let view = PreviewCard(image: image, title: title, subtitle: subtitle, fileURL: fileURL,
                               onClose: { [weak self] in self?.dismiss() })
        let host = NSHostingView(rootView: view)
        host.sizingOptions = [.intrinsicContentSize]

        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.contentView = host

        let size = host.fittingSize
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        panel.setFrame(CGRect(x: vf.maxX - size.width - 16, y: vf.minY + 16,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

private struct PreviewCard: View {
    let image: NSImage?
    let title: String
    let subtitle: String
    let fileURL: URL
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "film").font(.system(size: 28)).foregroundStyle(.secondary)
                        .frame(width: 96, height: 64)
                }
            }
            .frame(maxWidth: 140, maxHeight: 90)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))
            .onTapGesture { NSWorkspace.shared.open(fileURL) }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(L("preview.open"))

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(fileURL.lastPathComponent).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                HStack(spacing: 8) {
                    Button(L("preview.open")) { NSWorkspace.shared.open(fileURL); onClose() }
                    Button(L("preview.show_in_finder")) { NSWorkspace.shared.activateFileViewerSelecting([fileURL]); onClose() }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
            .frame(minWidth: 180, alignment: .leading)

            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("common.close"))
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1)))
        .frame(maxWidth: 420)
        .fixedSize()
    }
}
