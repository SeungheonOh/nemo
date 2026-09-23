import AppKit
import NemoCaret
import SwiftUI

/// Per-frame inputs for the caret effect that come from tracking rather than from the model.
final class CaretGeometry: ObservableObject {
    @Published var caretHeight: CGFloat = 18
}

/// A click-through panel that follows the insertion point of the focused app while text is typed
/// into it. When the caret cannot be located the panel stays invisible rather than guessing.
final class CaretGlowPanel {
    static let size: CGFloat = 120

    private let panel: NSPanel
    private let geometry = CaretGeometry()
    private var timer: Timer?
    private var inFlight = false
    private var placed = false
    private var shown = false
    private let queue = DispatchQueue(label: "dev.nemo.caret-locator", qos: .userInteractive)
    private let fixedRect: CGRect?   // demo mode: no tracking, a fixed spot on screen

    init(model: DictationModel) {
        let s = CaretGlowPanel.size
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: s, height: s),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        let hosting = NSHostingView(rootView: CaretGlowView(model: model, geometry: geometry))
        hosting.sizingOptions = []
        panel.contentView = hosting
        fixedRect = ProcessInfo.processInfo.environment["NEMO_DEMO"] == "caret" ? CGRect(x: 1100, y: 491, width: 2, height: 18) : nil
    }

    func setVisible(_ visible: Bool) {
        if visible { show() } else { hide() }
    }

    /// Called right after text was typed: the caret has just moved, catch up without waiting for the timer.
    func nudge() { if shown { poll() } }

    private func show() {
        guard !shown else { return }
        shown = true
        placed = false
        poll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func hide() {
        guard shown else { return }
        shown = false
        timer?.invalidate()
        timer = nil
        fade(to: 0, duration: 0.3, thenOrderOut: true)
    }

    private func poll() {
        if let fixedRect {
            place(CaretLocator.Hit(rect: fixedRect, precise: true, method: "demo"))
            return
        }
        guard !inFlight else { return }
        inFlight = true
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        queue.async { [weak self] in
            let hit = CaretLocator.locate(primaryHeight: primaryHeight)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                guard self.shown else { return }
                if let hit { self.place(hit) } else { self.lost() }
            }
        }
    }

    private func place(_ hit: CaretLocator.Hit) {
        geometry.caretHeight = min(max(hit.rect.height, 14), 44)
        let s = CaretGlowPanel.size
        let origin = NSPoint(x: hit.rect.midX - s / 2, y: hit.rect.midY - s / 2)
        if !placed {
            placed = true
            panel.setFrameOrigin(origin)
            panel.orderFrontRegardless()
            fade(to: 1, duration: 0.2, thenOrderOut: false)
        } else if abs(panel.frame.origin.x - origin.x) > 0.5 || abs(panel.frame.origin.y - origin.y) > 0.5 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrameOrigin(origin)
            }
            if panel.alphaValue < 1 { fade(to: 1, duration: 0.2, thenOrderOut: false) }
        }
    }

    /// No caret this tick (focus moved to something without text, or the app does not tell): go quiet.
    private func lost() {
        placed = false
        if panel.alphaValue > 0 { fade(to: 0, duration: 0.25, thenOrderOut: false) }
    }

    private func fade(to alpha: CGFloat, duration: Double, thenOrderOut: Bool) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            panel.animator().alphaValue = alpha
        }, completionHandler: { [panel] in
            if thenOrderOut, panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }
}

/// The effect: a slight glow around the caret that breathes and swells a little with the input
/// level, and under it the logo, a small black square (네모).
struct CaretGlowView: View {
    @ObservedObject var model: DictationModel
    @ObservedObject var geometry: CaretGeometry
    @State private var breathe = false
    @State private var bump = false

    var body: some View {
        let accent = model.state.caretColors[0]
        let writing = model.state == .listening
        let level = CGFloat(model.level)
        let h = geometry.caretHeight
        let radius: CGFloat = 13 + (breathe ? 3 : 0) + 7 * level
        ZStack {
            Ellipse()
                .fill(RadialGradient(colors: [accent.opacity(writing ? 0.38 : 0.22), accent.opacity(0.10), .clear],
                                     center: .center, startRadius: 0, endRadius: radius))
                .frame(width: radius * 2, height: max(radius * 2, h + 10))
                .blur(radius: 1.5)
                .animation(.easeOut(duration: 0.12), value: level)

            RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                .fill(.black)
                .frame(width: 7, height: 7)
                .overlay(RoundedRectangle(cornerRadius: 1.8, style: .continuous).strokeBorder(.white.opacity(0.5), lineWidth: 0.5))
                .shadow(color: accent.opacity(0.7), radius: 2.5)
                .scaleEffect(bump ? 1.3 : 1)
                .opacity(model.state == .loading ? (breathe ? 0.45 : 0.9) : 1)
                .offset(y: h / 2 + 9)
        }
        .frame(width: CaretGlowPanel.size, height: CaretGlowPanel.size)
        .onAppear { withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { breathe = true } }
        .onChange(of: model.insertPulse) { _, _ in
            withAnimation(.easeOut(duration: 0.08)) { bump = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { bump = false } }
        }
    }
}
