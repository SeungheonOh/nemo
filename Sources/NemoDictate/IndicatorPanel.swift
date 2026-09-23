import AppKit
import SwiftUI

/// A borderless, non-activating panel near the top of the screen that hosts the indicator.
final class IndicatorPanel {
    private let panel: NSPanel
    private var shown = false

    init(model: DictationModel) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 68),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true   // the window shadow follows the pill's alpha; SwiftUI shadows in a clear window render badly
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: IndicatorView(model: model))
        panel.alphaValue = 0
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [panel] in panel.invalidateShadow() }
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
        let origin = NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - 14)
        panel.setFrameOrigin(origin)
    }
}
