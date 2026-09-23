import AppKit
import Combine

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
        let busy = model.state == .loading || model.state == .finishing
        let name = listening ? "mic.fill" : (busy ? "mic.badge.xmark" : "mic")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "NemoDictate")
        image?.isTemplate = !listening
        item.button?.image = image
        item.button?.contentTintColor = listening ? .systemRed : nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Start Listening", action: #selector(toggle(_:)), keyEquivalent: " ")
        toggle.keyEquivalentModifierMask = [.option]
        toggle.target = self
        toggle.tag = 1
        menu.addItem(toggle)
        let copy = NSMenuItem(title: "Copy Last Transcript", action: #selector(copyLast(_:)), keyEquivalent: "")
        copy.target = self
        copy.tag = 2
        menu.addItem(copy)
        menu.addItem(.separator())

        let langMenu = NSMenu()
        for (code, name) in DictationModel.languages {
            let mi = NSMenuItem(title: "\(name) (\(code))", action: #selector(pickLanguage(_:)), keyEquivalent: "")
            mi.representedObject = code
            mi.target = self
            langMenu.addItem(mi)
        }
        let lang = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        lang.submenu = langMenu
        menu.addItem(lang)

        let latMenu = NSMenu()
        for ms in DictationModel.latencies {
            let mi = NSMenuItem(title: "\(ms) ms", action: #selector(pickLatency(_:)), keyEquivalent: "")
            mi.representedObject = ms
            mi.target = self
            latMenu.addItem(mi)
        }
        let lat = NSMenuItem(title: "Chunk latency", action: nil, keyEquivalent: "")
        lat.submenu = latMenu
        menu.addItem(lat)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NemoDictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let toggle = menu.item(withTag: 1) {
            toggle.title = model.state == .listening ? "Stop Listening" : "Start Listening"
            toggle.isEnabled = !(model.state == .loading || model.state == .finishing)
        }
        menu.item(withTag: 2)?.isEnabled = !model.lastTranscript.isEmpty
        for sub in menu.items.compactMap(\.submenu) {
            for mi in sub.items {
                if let code = mi.representedObject as? String { mi.state = code == model.language ? .on : .off }
                if let ms = mi.representedObject as? Int { mi.state = ms == model.latencyMs ? .on : .off }
            }
        }
    }

    @objc private func toggle(_ sender: Any?) { model.toggle() }
    @objc private func copyLast(_ sender: Any?) { model.copyLast() }
    @objc private func pickLanguage(_ sender: NSMenuItem) { if let c = sender.representedObject as? String { model.language = c } }
    @objc private func pickLatency(_ sender: NSMenuItem) { if let ms = sender.representedObject as? Int { model.latencyMs = ms } }
}
