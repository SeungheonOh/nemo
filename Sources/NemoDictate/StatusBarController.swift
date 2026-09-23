import AppKit
import Combine
import NemoAudio

/// Menu bar item: shows whether we are listening and holds the menu.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: DictationModel
    private var cancellables: Set<AnyCancellable> = []

    init(model: DictationModel) {
        self.model = model
        super.init()
        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "NemoDictate")
        item.menu = buildMenu()
        item.menu?.delegate = self
        model.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        refresh()
    }

    func refresh() {
        let listening = model.state == .listening
        let standby = model.state == .standby
        let busy = model.state == .loading || model.state == .finishing
        let failed = model.state == .failed
        let name = listening ? "mic.fill" : standby ? "ear" : failed ? "exclamationmark.triangle" : (busy ? "mic.badge.xmark" : "mic")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "NemoDictate")
        image?.isTemplate = !listening && !failed
        item.button?.image = image
        item.button?.contentTintColor = listening ? .systemRed : standby ? .systemTeal : failed ? .systemOrange : nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Start Dictating", action: #selector(toggle(_:)), keyEquivalent: " ")
        toggle.keyEquivalentModifierMask = [.option]
        toggle.target = self
        toggle.tag = 1
        menu.addItem(toggle)
        let wake = NSMenuItem(title: "Wake-Word Mode", action: #selector(toggleWake(_:)), keyEquivalent: "")
        wake.target = self
        wake.tag = 4
        menu.addItem(wake)
        let copy = NSMenuItem(title: "Copy Last Transcript", action: #selector(copyLast(_:)), keyEquivalent: "")
        copy.target = self
        copy.tag = 2
        menu.addItem(copy)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NemoDictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // the status line lives here: the app has no window of its own
        if menu.item(withTag: 9) == nil {
            let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            status.tag = 9
            status.isEnabled = false
            menu.insertItem(status, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        menu.item(withTag: 9)?.title = model.statusLine.isEmpty ? "Idle" : model.statusLine
        if let toggle = menu.item(withTag: 1) {
            switch model.state {
            case .listening: toggle.title = "Stop Dictating"
            case .standby: toggle.title = "Dictate Now (skip the wake word)"
            default: toggle.title = "Start Dictating"
            }
            toggle.isEnabled = !(model.state == .loading || model.state == .finishing)
        }
        menu.item(withTag: 2)?.isEnabled = !model.lastTranscript.isEmpty
        if let wake = menu.item(withTag: 4) {
            wake.state = model.wakeMode ? .on : .off
            wake.title = "Wake-Word Mode (“\(model.wakeWord)”)"
        }
    }

    @objc private func toggle(_ sender: Any?) { model.toggle() }
    @objc private func copyLast(_ sender: Any?) { model.copyLast() }
    @objc private func toggleWake(_ sender: NSMenuItem) { model.setWakeMode(!model.wakeMode) }
    @objc private func openSettings(_ sender: Any?) { SettingsWindow.shared.show(model: model) }
}
