import AppKit
import ApplicationServices
import Carbon

/// Types text into whatever has keyboard focus, using synthetic key events carrying Unicode.
/// Needs the Accessibility permission (System Settings > Privacy & Security > Accessibility).
enum TextInserter {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Returns true if trusted; otherwise asks macOS to show the permission prompt (once).
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static var frontmostAppName: String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "the focused app"
    }

    static func type(_ text: String) {
        guard !text.isEmpty, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            i += chunk.count
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
            chunk.withUnsafeBufferPointer { p in
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: p.baseAddress)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: p.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(2000)
        }
    }
}
