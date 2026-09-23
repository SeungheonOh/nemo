import AppKit
import SwiftUI

/// A borderless, non-activating panel near the top of the screen that hosts the indicator.
/// The window is larger than the pill by `IndicatorView.glowPadding` on every side so the
/// underglow and shadow, both drawn by SwiftUI, never get clipped.
final class IndicatorPanel {
    private let panel: NSPanel
    private var shown = false

    init(model: DictationModel) {
        let pad = IndicatorView.glowPadding
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: IndicatorView.width + 2 * pad, height: IndicatorView.minHeight + 2 * pad),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        // the pill is anchored to the top of the window and reports its height; the window follows it downward
        let root = IndicatorView(model: model, onHeightChange: { [weak self] h in self?.fit(pillHeight: h) })
            .padding(pad)
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
    }

    private func fit(pillHeight: CGFloat) {
        let h = max(IndicatorView.minHeight, ceil(pillHeight)) + 2 * IndicatorView.glowPadding
        var f = panel.frame
        guard abs(f.height - h) > 0.5 else { return }
        let top = f.maxY
        f.size.height = h
        f.origin.y = top - h
        panel.setFrame(f, display: true)
    }

    func setVisible(_ visible: Bool) {
        if visible { show() } else { hide() }
    }

    private func show() {
        if !shown {
            position()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            shown = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }
    }

    private func hide() {
        guard shown else { return }
        shown = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }

    private func position() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        let size = panel.frame.size
        let pillTop = f.maxY - 14
        let origin = NSPoint(x: f.midX - size.width / 2, y: pillTop + IndicatorView.glowPadding - size.height)
        panel.setFrameOrigin(origin)
    }
}
