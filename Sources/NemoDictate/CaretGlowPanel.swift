import AppKit
import ApplicationServices
import NemoCaret
import SwiftUI

/// Per-frame inputs for the caret effect that come from tracking rather than from the model.
final class CaretGeometry: ObservableObject {
    @Published var caretHeight: CGFloat = 18
    @Published var velocity = CGVector.zero   // points per second the glow is gliding at (AppKit axes, +y up)
    @Published var spawn = 0                  // bumps whenever the glow (re)appears, for the entrance animation
    var speed: CGFloat { hypot(velocity.dx, velocity.dy) }
}

/// A click-through panel that follows the insertion point of the focused app while text is typed
/// into it. Position updates come from AX notifications and a slow safety poll; the window glides
/// to each new position instead of jumping. When the caret cannot be located it stays invisible.
final class CaretGlowPanel {
    static let size: CGFloat = 120

    private let panel: NSPanel
    private let geometry = CaretGeometry()
    private var timer: Timer?             // safety-net poll
    private var motion: Timer?            // 60 Hz glide toward `target`
    private var target = NSPoint.zero
    private var current = NSPoint.zero
    private var lastTick = Date()
    private var inFlight = false
    private var placed = false
    private var shown = false
    private let queue = DispatchQueue(label: "dev.nemo.caret-locator", qos: .userInteractive)
    private var fixedRect: CGRect?        // demo mode: no tracking, a spot on screen that advances per chunk
    private var lastNote = ""
    private var lastLogged = (rect: CGRect.zero, at: Date.distantPast)
    private var lastPrecise = Date.distantPast
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var releaseTask: DispatchWorkItem?
    private var provisional: NSPoint?             // a rough position (edge of an empty field) held back in case the caret shows up
    private var provisionalTask: DispatchWorkItem?
    private var moveGeneration = 0
    private var demoTicks = 0

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
        if fixedRect != nil {
            demoTicks += 1
            fixedRect!.origin.x += demoTicks % 12 == 0 ? 320 : 9   // a far move now and then, to see the cross-fade
        }
        poll()
        for ms in [40, 120, 300] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in self?.poll() }
        }
    }

    // MARK: - lifecycle

    private func show() {
        guard !shown else { return }
        shown = true
        placed = false
        lastNote = ""
        lastPrecise = .distantPast
        releaseTask?.cancel()
        DebugLog.write("caret tracking on · trusted \(AXIsProcessTrusted()) · front app \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")")
        observe(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        poll()
        timer?.invalidate()
        // the observer reports selection changes as they happen; this only catches scrolling and
        // window moves, which have no text notification
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func hide() {
        guard shown else { return }
        shown = false
        timer?.invalidate()
        timer = nil
        stopMotion()
        provisionalTask?.cancel()
        provisionalTask = nil
        provisional = nil
        unobserve()
        fade(to: 0, duration: 0.3, thenOrderOut: true)
        // give browsers their normal behaviour back once dictation has been quiet for a while
        let task = DispatchWorkItem { CaretLocator.releaseWebContent() }
        releaseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: task)
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

    // MARK: - locating

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

    // MARK: - motion

    private func place(_ hit: CaretLocator.Hit) {
        geometry.caretHeight = min(max(hit.rect.height, 14), 44)
        let s = CaretGlowPanel.size
        let origin = NSPoint(x: hit.rect.midX - s / 2, y: hit.rect.midY - s / 2)
        if !placed {
            if hit.precise {
                appear(at: origin)
            } else {
                // only the edge of an empty field is known: the caret itself usually reports a moment
                // later (once the first word lands), so wait for it rather than appear and then jump
                provisional = origin
                if provisionalTask == nil {
                    let task = DispatchWorkItem { [weak self] in
                        guard let self, self.shown, !self.placed, let p = self.provisional else { return }
                        self.provisionalTask = nil
                        self.appear(at: p)
                    }
                    provisionalTask = task
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: task)
                }
            }
            return
        }
        let dist = hypot(target.x - origin.x, target.y - origin.y)
        guard dist > 0.5 else { return }
        target = origin
        if dist > 260 {
            // focus moved somewhere else entirely: fade out here and come back up there
            crossFade()
            return
        }
        if panel.alphaValue < 1 { fade(to: 1, duration: 0.2, thenOrderOut: false) }
        startMotion()
    }

    /// First appearance in a session, or after the caret was lost: settle the window and let the
    /// view play its entrance.
    private func appear(at origin: NSPoint) {
        provisionalTask?.cancel()
        provisionalTask = nil
        provisional = nil
        placed = true
        current = origin
        target = origin
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        geometry.spawn += 1
        fade(to: 1, duration: 0.22, thenOrderOut: false)
    }

    private func crossFade() {
        stopMotion()
        moveGeneration += 1
        let gen = moveGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.shown, self.moveGeneration == gen else { return }
            self.current = self.target   // the target may have moved on during the fade
            self.panel.setFrameOrigin(self.current)
            self.geometry.spawn += 1
            self.fade(to: 1, duration: 0.18, thenOrderOut: false)
        })
    }

    private func startMotion() {
        guard motion == nil else { return }
        lastTick = Date()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        motion = t
    }

    private func stopMotion() {
        motion?.invalidate()
        motion = nil
        geometry.velocity = .zero
    }

    /// Ease toward the target: a first-order glide with an 85 ms time constant, so a word-sized hop
    /// takes about a quarter of a second and never overshoots.
    private func tick() {
        let now = Date()
        let dt = max(0.001, now.timeIntervalSince(lastTick))
        lastTick = now
        let dx = target.x - current.x, dy = target.y - current.y
        let dist = hypot(dx, dy)
        if dist < 0.25 {
            current = target
            panel.setFrameOrigin(current)
            stopMotion()
            return
        }
        let k = 1 - exp(-dt / 0.085)
        current.x += dx * k
        current.y += dy * k
        panel.setFrameOrigin(current)
        geometry.velocity = CGVector(dx: dx * k / dt, dy: dy * k / dt)
    }

    /// No caret this tick (focus moved to something without text, or the app does not tell): go quiet.
    private func lost() {
        placed = false
        provisional = nil
        provisionalTask?.cancel()
        provisionalTask = nil
        stopMotion()
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

/// The effect: a soft glow around the caret in two layers that breathes, swells a little with the
/// input level and stretches slightly while gliding; under it the logo, a small black square (네모)
/// that hangs from the glow, trailing and leaning into the motion, and sends out a faint ring each
/// time a chunk of text lands. Appearances start small and spring to size.
struct CaretGlowView: View {
    @ObservedObject var model: DictationModel
    @ObservedObject var geometry: CaretGeometry
    @State private var breathe = false
    @State private var flash = false
    @State private var ring: Double = 1          // 0 → 1 over a pulse; 1 means gone
    @State private var entrance: CGFloat = 1

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
        let v = geometry.velocity
        let stretch = min(geometry.speed / 900, 0.6)
        // the square hangs from the glow: it trails the motion a little and leans into it
        let lagX = max(-9, min(9, -v.dx * 0.012))
        let lagY = max(-6, min(6, v.dy * 0.010))     // AppKit +y is up; SwiftUI +y is down
        let tilt = Angle.degrees(Double(max(-16, min(16, v.dx * 0.025))))
        let r: CGFloat = 12 + (breathe ? 2.5 : 0) + 6 * level
        ZStack {
            // wide, faint halo
            Ellipse()
                .fill(RadialGradient(colors: [accent.opacity(writing ? 0.20 : 0.12), .clear], center: .center, startRadius: 0, endRadius: r * 1.9))
                .frame(width: r * 3.8 * (1 + stretch), height: max(r * 3.8, h + 18))
                .blur(radius: 3)
            // tight core
            Ellipse()
                .fill(RadialGradient(colors: [accent.opacity(writing ? 0.5 : 0.28), accent.opacity(0.12), .clear], center: .center, startRadius: 0, endRadius: r))
                .frame(width: r * 2 * (1 + stretch), height: max(r * 2, h + 6))
                .blur(radius: 1.5)
                .brightness(flash ? 0.2 : 0)
            // pulse ring drifting out from the square
            Circle()
                .strokeBorder(accent.opacity(0.6 * (1 - ring)), lineWidth: 1)
                .frame(width: 9 + 30 * ring, height: 9 + 30 * ring)
                .offset(x: lagX, y: h / 2 + 9 + lagY)
            // the logo
            RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                .fill(.black)
                .frame(width: 7, height: 7)
                .overlay(RoundedRectangle(cornerRadius: 1.8, style: .continuous).strokeBorder(.white.opacity(0.5), lineWidth: 0.5))
                .shadow(color: accent.opacity(flash ? 0.95 : 0.6), radius: flash ? 4.5 : 2.5)
                .rotationEffect(tilt)
                .scaleEffect(flash ? 1.22 : 1)
                .opacity(model.state == .loading ? (breathe ? 0.45 : 0.9) : 1)
                .offset(x: lagX, y: h / 2 + 9 + lagY)
        }
        .scaleEffect(entrance)
        .animation(.easeOut(duration: 0.12), value: level)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: geometry.velocity)
        .frame(width: CaretGlowPanel.size, height: CaretGlowPanel.size)
        .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true } }
        .onChange(of: geometry.spawn) { _, _ in
            // start small and spring to size; the two assignments must land in separate transactions
            entrance = 0.55
            DispatchQueue.main.async { withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { entrance = 1 } }
        }
        .onChange(of: model.insertPulse) { _, _ in
            ring = 0
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.6)) { ring = 1 } }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { flash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { flash = false } }
        }
    }
}
