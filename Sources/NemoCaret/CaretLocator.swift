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
    public static func locate(primaryHeight: CGFloat) -> Hit? {
        guard let focused = focusedElement() else { return nil }
        if let (r, how) = caretBounds(focused) {
            return Hit(rect: flip(r, primaryHeight), precise: true, method: how)
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
    public static func diagnose(primaryHeight: CGFloat) -> (hit: Hit?, note: String) {
        guard let el = focusedElement() else { return (nil, "no focused element (AX error \(lastError.rawValue), front app \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"))") }
        let role = "\(string(el, kAXRoleAttribute) ?? "?")/\(string(el, kAXSubroleAttribute) ?? "-")"
        let hit = locate(primaryHeight: primaryHeight)
        if let hit { return (hit, "\(hit.method) in \(role)") }
        var why = "no caret in \(role)"
        if let r = range(el, kAXSelectedTextRangeAttribute) {
            why += ", range (\(r.location),\(r.length))"
            _ = bounds(el, r); why += ", bounds err \(lastError.rawValue)"
        } else {
            why += ", no selected range (err \(lastError.rawValue))"
        }
        _ = markerBounds(el); why += ", marker err \(lastError.rawValue)"
        if let sz = size(el, kAXSizeAttribute) { why += ", size \(Int(sz.width))x\(Int(sz.height))" }
        return (nil, why)
    }

    // MARK: - lookup strategies

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard let el = element(system, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }

    /// Bounds of the insertion point. A collapsed selection usually has no bounds of its own, so the
    /// character after it, then the one before it, is measured; WebKit/Chromium text markers are the
    /// fallback for editors that do not answer for plain ranges.
    private static func caretBounds(_ el: AXUIElement) -> (CGRect, String)? {
        if let r = range(el, kAXSelectedTextRangeAttribute) {
            if r.length > 0, let b = bounds(el, r) {
                return (CGRect(x: b.maxX, y: b.minY, width: 2, height: b.height), "selection end")   // typing replaces the selection
            }
            if r.length == 0 {
                if let b = bounds(el, r), b.width < 4 {   // some editors answer for the empty range itself
                    return (CGRect(x: b.minX, y: b.minY, width: 2, height: b.height), "caret range")
                }
                if let b = bounds(el, CFRange(location: r.location, length: 1)) {
                    return (CGRect(x: b.minX, y: b.minY, width: 2, height: b.height), "char after caret")
                }
                if r.location > 0, let b = bounds(el, CFRange(location: r.location - 1, length: 1)) {
                    return (CGRect(x: b.maxX, y: b.minY, width: 2, height: b.height), "char before caret")
                }
            }
        }
        if let b = markerBounds(el) {
            return (CGRect(x: b.minX, y: b.minY, width: 2, height: b.height), "text marker range")
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
        var mref: CFTypeRef?
        lastError = AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &mref)
        guard lastError == .success, let marker = mref else { return nil }
        var ref: CFTypeRef?
        lastError = AXUIElementCopyParameterizedAttributeValue(el, "AXBoundsForTextMarkerRange" as CFString, marker, &ref)
        guard lastError == .success, let v = ref, let rect = rect(v), rect.height > 0 else { return nil }
        return rect
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
