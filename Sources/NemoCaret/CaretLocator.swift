import AppKit
import ApplicationServices

/// Finds where the focused app is about to insert text, through the Accessibility API.
/// Precise when the app reports bounds for its selection (Cocoa text views, WebKit and Chromium
/// text fields); for a small single-line field that gives no bounds, its left edge. Never guesses.
public enum CaretLocator {
    public struct Hit {
        public let rect: CGRect      // AppKit screen coordinates (origin bottom-left of the primary display)
        public let precise: Bool
        public let method: String
        public init(rect: CGRect, precise: Bool, method: String) { self.rect = rect; self.precise = precise; self.method = method }
    }

    /// `primaryHeight` is `NSScreen.screens[0].frame.height`, read on the main thread by the caller.
    public static func locate(primaryHeight: CGFloat, pid: pid_t?) -> Hit? {
        guard var focused = focusedElement(pid: pid) else { return nil }
        if let (r, how) = caretBounds(focused) {
            return Hit(rect: flip(r, primaryHeight), precise: true, method: how)
        }
        // focus sits on a container (a browser's web view with its tree still off): wake it and look again
        if let pid, !isTextRole(string(focused, kAXRoleAttribute)), wakeWebContent(pid: pid),
           let again = focusedElement(pid: pid) {
            focused = again
            if let (r, how) = caretBounds(focused) {
                return Hit(rect: flip(r, primaryHeight), precise: true, method: how)
            }
        }
        if let pid, (raw(focused, "AXDOMClassList") as? [String])?.contains("OmniboxViewViews") == true, wakeWebContent(pid: pid) {
            // Chrome reports its URL bar as focused while the web tree is still off; the tree is on its
            // way now, so do not glow on the address bar in the meantime
            return nil
        }
        if let pos = point(focused, kAXPositionAttribute), let size = self.size(focused, kAXSizeAttribute),
           size.width > 0, size.height > 0, size.height < 60 {
            // a single-line field that gives no range bounds (usually empty): the caret is at its left edge.
            // Bigger elements are skipped: a glow in the corner of a page or document is not on the caret.
            let f = flip(CGRect(origin: pos, size: size), primaryHeight)
            let caretH = min(18, f.height - 6)
            return Hit(rect: CGRect(x: f.minX + 12, y: f.midY - caretH / 2, width: 2, height: caretH), precise: false, method: "field frame")
        }
        return nil
    }

    /// The hit plus one line saying how it was found, or why not, for the app's log.
    public static func diagnose(primaryHeight: CGFloat, pid: pid_t?) -> (hit: Hit?, note: String) {
        guard let el = focusedElement(pid: pid) else { return (nil, "no focused element (AX error \(lastError.rawValue), pid \(pid.map(String.init) ?? "-"))") }
        var role = "\(string(el, kAXRoleAttribute) ?? "?")/\(string(el, kAXSubroleAttribute) ?? "-")"
        // web content: which DOM element this is
        if let id = string(el, "AXDOMIdentifier"), !id.isEmpty { role += " #\(id)" }
        if let cls = raw(el, "AXDOMClassList") as? [String], !cls.isEmpty { role += " .\(cls.prefix(3).joined(separator: "."))" }
        let hit = locate(primaryHeight: primaryHeight, pid: pid)
        if let hit { return (hit, "\(hit.method) in \(role)") }
        var why = "no caret in \(role)"
        if let r = range(el, kAXSelectedTextRangeAttribute) {
            why += ", range (\(r.location),\(r.length))"
            _ = bounds(el, r); why += ", bounds err \(lastError.rawValue)"
        } else {
            why += ", no selected range (err \(lastError.rawValue))"
        }
        if let sel = raw(el, "AXSelectedTextMarkerRange") {
            let end = param(el, "AXEndTextMarkerForTextMarkerRange", sel); why += ", end marker \(end == nil ? "err \(lastError.rawValue)" : "ok")"
            if let end { _ = param(el, "AXPreviousTextMarkerForTextMarker", end); why += ", prev marker err \(lastError.rawValue)" }
            _ = markerBounds(el); why += ", marker bounds err \(lastError.rawValue)"
        } else {
            why += ", no marker range (err \(lastError.rawValue))"
        }
        if let sz = size(el, kAXSizeAttribute) { why += ", size \(Int(sz.width))x\(Int(sz.height))" }
        return (nil, why)
    }

    // MARK: - lookup strategies

    private static var lastWake: [pid_t: Date] = [:]

    private static func focusedElement(pid: pid_t?) -> AXUIElement? {
        if let pid {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            if let el = element(app, kAXFocusedUIElementAttribute) { AXUIElementSetMessagingTimeout(el, 0.25); return el }
            if wakeWebContent(pid: pid), let el = element(app, kAXFocusedUIElementAttribute) {
                AXUIElementSetMessagingTimeout(el, 0.25)
                return el
            }
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard let el = element(system, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }

    private static func isTextRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"].contains(role)
    }

    /// Browsers and Electron apps keep their web accessibility tree switched off until an assistive
    /// client shows up. Electron has its own attribute for that (AXManualAccessibility, immediate).
    /// Chrome and its forks only listen to the flag VoiceOver sets, AXEnhancedUserInterface, and switch
    /// their complete mode on two seconds after it is set (chrome_browser_application_mac.mm); the
    /// role-query shortcut newer Chromium has is behind a flag that is off by default. Rate-limited per
    /// process; returns false when it was not this process's turn.
    @discardableResult
    private static func wakeWebContent(pid: pid_t) -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastWake[pid] ?? .distantPast) > 3 else { return false }
        lastWake[pid] = now
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let electron = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        if !electron, AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success {
            enhancedLock.lock(); enhanced.insert(pid); enhancedLock.unlock()
        }
        // newer Chromium (flag-gated) turns basic mode on when the web view is asked for its role;
        // cheap to try: whatever sits under the window's centre, and its ancestors
        if let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute),
           let pos = point(window, kAXPositionAttribute), let size = self.size(window, kAXSizeAttribute) {
            var hitRef: AXUIElement?
            if AXUIElementCopyElementAtPosition(app, Float(pos.x + size.width / 2), Float(pos.y + size.height / 2), &hitRef) == .success, var el = hitRef {
                for _ in 0..<8 {
                    _ = string(el, kAXRoleAttribute)
                    guard let parent = element(el, kAXParentAttribute) else { break }
                    el = parent
                }
            }
        }
        return true
    }

    private static var enhanced = Set<pid_t>()
    private static let enhancedLock = NSLock()

    /// Chrome treats AXEnhancedUserInterface as "a screen reader is here" and, among other things,
    /// animates window moves while it is set, which upsets window managers. Clear it when the glow has
    /// been idle for a while and on quit; Chrome drops the mode two seconds later.
    public static func releaseWebContent() {
        enhancedLock.lock()
        let pids = enhanced
        enhanced.removeAll()
        enhancedLock.unlock()
        for pid in pids where NSRunningApplication(processIdentifier: pid) != nil {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
    }

    /// Bounds of the insertion point. A collapsed selection usually has no bounds of its own, so the
    /// character after it, then the one before it, is measured; WebKit/Chromium text markers are the
    /// fallback for editors that do not answer for plain ranges.
    private static func caretBounds(_ el: AXUIElement) -> (CGRect, String)? {
        if let r = range(el, kAXSelectedTextRangeAttribute), let hit = rangeCaret(el, r) { return hit }
        if let hit = markerCaret(el) { return hit }
        return nil
    }

    /// Plain-range path (Cocoa text views, atomic text fields, Chromium <input>/<textarea>).
    private static func rangeCaret(_ el: AXUIElement, _ r: CFRange) -> (CGRect, String)? {
        if r.length > 0 {
            guard let b = bounds(el, r) else { return nil }
            return (CGRect(x: b.maxX, y: b.minY, width: 2, height: b.height), "selection end")   // typing replaces the selection
        }
        // the caret has no bounds of its own: use the right edge of the character before it, unless that
        // character is a line break (then the caret sits at the start of the next line, left of the char after)
        let before = CFRange(location: r.location - 1, length: 1)
        let beforeIsBreak = r.location > 0 && (stringFor(el, before)?.contains(where: { $0.isNewline }) ?? false)
        if r.location > 0, !beforeIsBreak, let b = bounds(el, before) {
            return (CGRect(x: b.maxX, y: b.minY, width: 2, height: b.height), "char before caret")
        }
        if let b = bounds(el, CFRange(location: r.location, length: 1)) {
            return (CGRect(x: b.minX, y: b.minY, width: 2, height: b.height), "char after caret")
        }
        if let b = bounds(el, r), b.width < 4 {   // some editors answer for the empty range itself
            return (CGRect(x: b.minX, y: b.minY, width: 2, height: b.height), "caret range")
        }
        return nil
    }

    /// Text-marker path (WebKit, Chromium and Electron rich-text editors). The bounds of a collapsed
    /// marker range are not the caret there, so walk one character from the selection's end marker.
    private static func markerCaret(_ el: AXUIElement) -> (CGRect, String)? {
        guard let sel = raw(el, "AXSelectedTextMarkerRange") else { return nil }
        if let end = param(el, "AXEndTextMarkerForTextMarkerRange", sel) {
            var beforeIsBreak = false
            if let prev = param(el, "AXPreviousTextMarkerForTextMarker", end),
               let range = param(el, "AXTextMarkerRangeForUnorderedTextMarkers", [prev, end] as CFArray) {
                beforeIsBreak = (param(el, "AXStringForTextMarkerRange", range) as? String)?.contains(where: { $0.isNewline }) ?? false
                if !beforeIsBreak, let b = paramRect(el, "AXBoundsForTextMarkerRange", range), b.height > 0, b.width < 200 {
                    return (CGRect(x: b.maxX, y: b.minY, width: 2, height: b.height), "marker before caret")
                }
            }
            if let next = param(el, "AXNextTextMarkerForTextMarker", end),
               let range = param(el, "AXTextMarkerRangeForUnorderedTextMarkers", [end, next] as CFArray),
               let b = paramRect(el, "AXBoundsForTextMarkerRange", range), b.height > 0, b.width < 200 {
                return (CGRect(x: b.minX, y: b.minY, width: 2, height: b.height), "marker after caret")
            }
        }
        if let b = paramRect(el, "AXBoundsForTextMarkerRange", sel), b.height > 0, b.width < 4 {
            return (CGRect(x: b.minX, y: b.minY, width: 2, height: b.height), "marker range")
        }
        return nil
    }

    private static func bounds(_ el: AXUIElement, _ range: CFRange) -> CGRect? {
        var r = range
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        var ref: CFTypeRef?
        lastError = AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, param, &ref)
        guard lastError == .success, let v = ref, let rect = rect(v), rect.height > 0 else { return nil }
        return rect
    }

    private static func markerBounds(_ el: AXUIElement) -> CGRect? {
        guard let sel = raw(el, "AXSelectedTextMarkerRange") else { return nil }
        return paramRect(el, "AXBoundsForTextMarkerRange", sel)
    }

    private static func stringFor(_ el: AXUIElement, _ range: CFRange) -> String? {
        var r = range
        guard let p = AXValueCreate(.cfRange, &r) else { return nil }
        return param(el, kAXStringForRangeParameterizedAttribute, p) as? String
    }

    private static func param(_ el: AXUIElement, _ attr: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var ref: CFTypeRef?
        lastError = AXUIElementCopyParameterizedAttributeValue(el, attr as CFString, parameter, &ref)
        return lastError == .success ? ref : nil
    }

    private static func paramRect(_ el: AXUIElement, _ attr: String, _ parameter: CFTypeRef) -> CGRect? {
        guard let v = param(el, attr, parameter), let r = rect(v), r.height > 0 else { return nil }
        return r
    }

    // MARK: - AX plumbing

    private static var lastError: AXError = .success

    private static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var ref: CFTypeRef?
        lastError = AXUIElementCopyAttributeValue(el, attr as CFString, &ref)
        guard lastError == .success, let v = ref, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXUIElement.self)
    }

    private static func raw(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        lastError = AXUIElementCopyAttributeValue(el, attr as CFString, &ref)
        return lastError == .success ? ref : nil
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? { raw(el, attr) as? String }

    private static func range(_ el: AXUIElement, _ attr: String) -> CFRange? {
        guard let v = raw(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var out = CFRange()
        return withUnsafeMutablePointer(to: &out) { AXValueGetValue(unsafeBitCast(v, to: AXValue.self), .cfRange, UnsafeMutableRawPointer($0)) } ? out : nil
    }

    private static func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        guard let v = raw(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var out = CGPoint.zero
        return withUnsafeMutablePointer(to: &out) { AXValueGetValue(unsafeBitCast(v, to: AXValue.self), .cgPoint, UnsafeMutableRawPointer($0)) } ? out : nil
    }

    private static func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        guard let v = raw(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var out = CGSize.zero
        return withUnsafeMutablePointer(to: &out) { AXValueGetValue(unsafeBitCast(v, to: AXValue.self), .cgSize, UnsafeMutableRawPointer($0)) } ? out : nil
    }

    private static func rect(_ v: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var out = CGRect.zero
        return withUnsafeMutablePointer(to: &out) { AXValueGetValue(unsafeBitCast(v, to: AXValue.self), .cgRect, UnsafeMutableRawPointer($0)) } ? out : nil
    }

    /// AX reports Quartz coordinates (origin top-left of the primary display); AppKit wants bottom-left.
    private static func flip(_ r: CGRect, _ primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}
