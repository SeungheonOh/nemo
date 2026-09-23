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
        if ProcessInfo.processInfo.environment["NEMO_DEMO"] == "caret" { model.demoCaret(); return }
        if model.wakeMode { model.start() }
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in self?.model.toggle() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CaretLocator.releaseWebContent()
        if model.isRunning { model.stop() }
    }
}
