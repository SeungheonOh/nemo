import AppKit
import Carbon

/// Menu-bar-only app: Option+Space (or the menu) starts listening; the model loads on demand
/// (about 300 ms), a floating indicator shows the live transcript, and stopping copies the text
/// to the clipboard and releases the model.
@main
enum NemoDictateMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = DictationModel()
    private var statusBar: StatusBarController?
    private var panel: IndicatorPanel?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = IndicatorPanel(model: model)
        self.panel = panel
        statusBar = StatusBarController(model: model)
        model.onStateChange = { [weak self] state in self?.panel?.update(for: state) }
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in self?.model.toggle() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if model.state == .listening { model.stop() }
    }
}
