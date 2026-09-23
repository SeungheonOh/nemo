import AppKit
import NemoCaret

// Prints what the caret lookup sees in the focused app, twice a second, until Ctrl-C.
// Run it from a terminal that has Accessibility access, click into the app you want to dictate into.
let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
while true {
    print("\u{1B}[2J\u{1B}[H" + CaretLocator.report(primaryHeight: primaryHeight))
    fflush(stdout)
    Thread.sleep(forTimeInterval: 0.5)
}
