import AppKit
import Carbon
import Combine

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
    private var caret: CaretGlowPanel?
    private var hotKey: HotKey?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = IndicatorPanel(model: model)
        self.panel = panel
        statusBar = StatusBarController(model: model)
        let caret = CaretGlowPanel(model: model)
        self.caret = caret
        model.$pillVisible.removeDuplicates().receive(on: DispatchQueue.main).sink { visible in panel.setVisible(visible) }.store(in: &cancellables)
        model.$caretEffectVisible.removeDuplicates().receive(on: DispatchQueue.main).sink { visible in caret.setVisible(visible) }.store(in: &cancellables)
        model.$insertPulse.dropFirst().receive(on: DispatchQueue.main).sink { _ in caret.nudge() }.store(in: &cancellables)
        if ProcessInfo.processInfo.environment["NEMO_DEMO"] != nil { model.demoStream(); return }
        if model.wakeMode { model.start() }
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in self?.model.toggle() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if model.isRunning { model.stop() }
    }
}
