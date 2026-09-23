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
        let name = listening ? "mic.fill" : standby ? "ear" : (busy ? "mic.badge.xmark" : "mic")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "NemoDictate")
        image?.isTemplate = !listening
        item.button?.image = image
        item.button?.contentTintColor = listening ? .systemRed : (standby ? .systemTeal : nil)
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

        let mic = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        mic.submenu = NSMenu()
        mic.tag = 3
        menu.addItem(mic)

        let outMenu = NSMenu()
        for (mode, title) in [(OutputMode.clipboard, "Copy to clipboard"), (OutputMode.type, "Type into the focused text field")] {
            let mi = NSMenuItem(title: title, action: #selector(pickOutput(_:)), keyEquivalent: "")
            mi.representedObject = mode.rawValue
            mi.target = self
            outMenu.addItem(mi)
        }
        let out = NSMenuItem(title: "Output", action: nil, keyEquivalent: "")
        out.submenu = outMenu
        out.tag = 4
        menu.addItem(out)

        let wakeMenu = NSMenu()
        let enable = NSMenuItem(title: "Wake-word mode (always listening)", action: #selector(toggleWake(_:)), keyEquivalent: "")
        enable.target = self
        enable.tag = 41
        wakeMenu.addItem(enable)
        let setWord = NSMenuItem(title: "Set wake word…", action: #selector(setWakeWord(_:)), keyEquivalent: "")
        setWord.target = self
        setWord.tag = 42
        wakeMenu.addItem(setWord)
        wakeMenu.addItem(.separator())
        for secs in DictationModel.silenceOptions {
            let mi = NSMenuItem(title: "Stop after \(String(format: "%.1f", secs)) s of silence", action: #selector(pickSilence(_:)), keyEquivalent: "")
            mi.representedObject = secs
            mi.target = self
            wakeMenu.addItem(mi)
        }
        let wake = NSMenuItem(title: "Wake word", action: nil, keyEquivalent: "")
        wake.submenu = wakeMenu
        wake.tag = 5
        menu.addItem(wake)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NemoDictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    /// The device list is rebuilt every time the menu opens, so plugging a mic in shows up immediately.
    private func rebuildMicrophoneMenu(_ sub: NSMenu) {
        sub.removeAllItems()
        let dflt = AudioInputDevice.systemDefault()
        let auto = NSMenuItem(title: "System Default" + (dflt.map { " (\($0.name))" } ?? ""), action: #selector(pickMic(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = model.micUID == nil ? .on : .off
        sub.addItem(auto)
        sub.addItem(.separator())
        var seen = false
        for device in AudioInputDevice.inputs() {
            let mi = NSMenuItem(title: "\(device.name)  ·  \(Int(device.sampleRate)) Hz, \(device.inputChannels) ch", action: #selector(pickMic(_:)), keyEquivalent: "")
            mi.representedObject = device.uid
            mi.target = self
            mi.state = device.uid == model.micUID ? .on : .off
            seen = seen || mi.state == .on
            sub.addItem(mi)
        }
        if let uid = model.micUID, !seen {
            let missing = NSMenuItem(title: "Chosen microphone not connected (\(uid))", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            sub.addItem(missing)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let mic = menu.item(withTag: 3)?.submenu { rebuildMicrophoneMenu(mic) }
        if let toggle = menu.item(withTag: 1) {
            switch model.state {
            case .listening: toggle.title = "Stop Transcribing"
            case .standby: toggle.title = "Start Transcribing Now"
            default: toggle.title = "Start Listening"
            }
            toggle.isEnabled = !(model.state == .loading || model.state == .finishing)
        }
        menu.item(withTag: 2)?.isEnabled = !model.lastTranscript.isEmpty
        for item in menu.items where item.tag != 3 && item.tag != 4 && item.tag != 5 {
            for mi in item.submenu?.items ?? [] {
                if let code = mi.representedObject as? String { mi.state = code == model.language ? .on : .off }
                if let ms = mi.representedObject as? Int { mi.state = ms == model.latencyMs ? .on : .off }
            }
        }
        for mi in menu.item(withTag: 4)?.submenu?.items ?? [] {
            mi.state = (mi.representedObject as? String) == model.outputMode.rawValue ? .on : .off
        }
        if let wake = menu.item(withTag: 5)?.submenu {
            wake.item(withTag: 41)?.state = model.wakeMode ? .on : .off
            wake.item(withTag: 42)?.title = "Set wake word… (“\(model.wakeWord)”)"
            for mi in wake.items { if let secs = mi.representedObject as? Double { mi.state = secs == model.silenceStop ? .on : .off } }
        }
    }

    @objc private func toggle(_ sender: Any?) { model.toggle() }
    @objc private func copyLast(_ sender: Any?) { model.copyLast() }
    @objc private func pickLanguage(_ sender: NSMenuItem) { if let c = sender.representedObject as? String { model.language = c } }
    @objc private func pickLatency(_ sender: NSMenuItem) { if let ms = sender.representedObject as? Int { model.latencyMs = ms } }
    @objc private func pickMic(_ sender: NSMenuItem) { model.micUID = sender.representedObject as? String }
    @objc private func pickOutput(_ sender: NSMenuItem) { if let raw = sender.representedObject as? String, let m = OutputMode(rawValue: raw) { model.setOutputMode(m) } }
    @objc private func pickSilence(_ sender: NSMenuItem) { if let s = sender.representedObject as? Double { model.silenceStop = s } }
    @objc private func toggleWake(_ sender: NSMenuItem) { model.setWakeMode(!model.wakeMode) }

    @objc private func setWakeWord(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Wake word"
        alert.informativeText = "Say this phrase to start transcribing while in wake-word mode. Two or three plain words work best; small recognition errors are tolerated."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = model.wakeWord
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let phrase = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !phrase.isEmpty { model.wakeWord = phrase }
        }
    }
}
