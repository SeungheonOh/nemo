import AppKit
import ApplicationServices
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
    private var lastNote = ""
    private var lastLogged = (rect: CGRect.zero, at: Date.distantPast)
    private var lastPrecise = Date.distantPast   // when the caret itself (not a fallback) was last seen
    private var observer: AXObserver?
    private var observedPID: pid_t = 0

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

    /// Called right after text was typed: the caret has just moved; the app needs a moment to lay out.
    func nudge() {
        guard shown else { return }
        poll()
        for ms in [40, 120, 300] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in self?.poll() }
        }
    }

    // MARK: - AX notifications

    /// Subscribe to selection, value and focus changes in the front app; they arrive on the main run loop.
    private func observe(_ pid: pid_t?) {
        guard let pid, pid != observedPID else { return }
        unobserve()
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<CaretGlowPanel>.fromOpaque(refcon).takeUnretainedValue().poll()
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        let app = AXUIElementCreateApplication(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXSelectedTextChangedNotification, kAXValueChangedNotification, kAXFocusedUIElementChangedNotification,
                     kAXWindowMovedNotification, kAXWindowResizedNotification] {
            AXObserverAddNotification(obs, app, name as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedPID = pid
    }

    private func unobserve() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        observedPID = 0
    }

    private func show() {
        guard !shown else { return }
        shown = true
        placed = false
        lastNote = ""
        lastPrecise = .distantPast
        DebugLog.write("caret tracking on · trusted \(AXIsProcessTrusted()) · front app \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")")
        observe(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        poll()
        timer?.invalidate()
        // the observer below reports selection changes as they happen; this only catches scrolling and
        // window moves, which have no text notification
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func hide() {
        guard shown else { return }
        shown = false
        timer?.invalidate()
        timer = nil
        unobserve()
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
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        observe(pid)
        queue.async { [weak self] in
            let (hit, note) = CaretLocator.diagnose(primaryHeight: primaryHeight, pid: pid)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                guard self.shown else { return }
                let moved = hit.map { abs($0.rect.minX - self.lastLogged.rect.minX) > 2 || abs($0.rect.minY - self.lastLogged.rect.minY) > 2 } ?? false
                if note != self.lastNote || (moved && Date().timeIntervalSince(self.lastLogged.at) > 0.4) {
                    self.lastNote = note
                    self.lastLogged = (hit?.rect ?? .zero, Date())
                    DebugLog.write(hit.map { "caret \(note) at \(Int($0.rect.minX)),\(Int($0.rect.minY)) h\(Int($0.rect.height))" } ?? "caret \(note)")
                }
                if let hit, hit.precise {
                    self.lastPrecise = Date()
                    self.place(hit)
                } else if Date().timeIntervalSince(self.lastPrecise) < 2 {
                    // the editor is mid-update (it happens while keystrokes land): stay where the caret was
                } else if let hit {
                    self.place(hit)
                } else {
                    self.lost()
                }
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
                ctx.duration = 0.07
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

    private var accent: Color {
        switch model.state {
        case .listening: return Color(red: 0.25, green: 0.90, blue: 1.00)
        case .done: return Color(red: 0.30, green: 0.90, blue: 0.55)
        default: return Color(red: 1.00, green: 0.70, blue: 0.25)
        }
    }

    var body: some View {
        let accent = self.accent
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
