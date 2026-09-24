import AppKit
import Carbon
import Combine
import NemoCaret

/// Menu-bar-only app. Option+Space (or the menu) starts dictating into whatever has keyboard focus;
/// in wake-word mode the microphone stays on and a spoken phrase starts a segment. The only UI is the
/// menu-bar item and a glow on the caret of the field being written to.
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
    private var caret: CaretGlowPanel?
    private var hotKey: HotKey?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController(model: model)
        let caret = CaretGlowPanel(model: model)
        self.caret = caret
        model.$caretEffectVisible.removeDuplicates().receive(on: DispatchQueue.main).sink { visible in caret.setVisible(visible) }.store(in: &cancellables)
        model.$insertPulse.dropFirst().receive(on: DispatchQueue.main).sink { _ in caret.nudge() }.store(in: &cancellables)
        if ModelStorage.isBundled {
            model.statusLine = "Preparing bundled model…"
            DispatchQueue.global(qos: .utility).async { [weak self] in
                do {
                    _ = try ModelStorage.prepareBundledModel()
                    DispatchQueue.main.async {
                        if self?.model.statusLine == "Preparing bundled model…" { self?.model.statusLine = "" }
                    }
                } catch {
                    DebugLog.write("model preparation failed: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        if self?.model.state == .idle { self?.model.statusLine = "Could not prepare the bundled model" }
                    }
                }
            }
        }
        if ProcessInfo.processInfo.environment["NEMO_DEMO"] == "caret" { model.demoCaret(); return }
        if ProcessInfo.processInfo.environment["NEMO_DEMO_MENU"] != nil {
            // UI work: pop the status menu up at a fixed spot
            model.statusLine = "Standing by for “spark” · MacBook Pro Microphone"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.statusBar?.popUpMenu(at: NSPoint(x: 400, y: 1200))
            }
            return
        }
        if let tab = ProcessInfo.processInfo.environment["NEMO_DEMO_SETTINGS"] {
            // UI work: open Settings at a fixed spot (top-left 200,200 in Quartz coordinates) on the given tab
            SettingsWindow.shared.show(model: model, tab: Int(tab) ?? 0, at: NSPoint(x: 200, y: 160))
            return
        }
        if model.wakeMode { model.start() }
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in self?.model.toggle() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CaretLocator.releaseWebContent()
        if model.isRunning { model.stop() }
    }
}
