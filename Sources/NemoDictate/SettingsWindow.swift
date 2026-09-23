import AppKit
import ApplicationServices
import NemoAudio
import SwiftUI

/// The settings window: a fixed-width titled window whose height follows the selected pane.
/// The app is menu-bar only, so the window activates the app while it is open.
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private var hosting: NSHostingController<SettingsView>?

    func show(model: DictationModel, tab: Int = 0, at origin: NSPoint? = nil) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model, tab: SettingsView.Tab(rawValue: tab) ?? .general,
                                                                  onResize: { [weak self] in self?.fit(animated: true) }))
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.title = "NemoDictate Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            hosting = host
            window = w
            fit(animated: false)
            w.center()
        }
        if let origin, let w = window, let screen = NSScreen.screens.first {
            w.setFrameTopLeftPoint(NSPoint(x: origin.x, y: screen.frame.height - origin.y))
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Size the window to the pane's ideal height, keeping the top edge where it is.
    private func fit(animated: Bool) {
        guard let w = window, let host = hosting else { return }
        // sizingOptions are off so the window does not snap on its own; ask SwiftUI for the ideal size
        let size = host.sizeThatFits(in: NSSize(width: 560, height: 4000))
        guard size.height > 0 else { return }
        var frame = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - frame.height)
        w.setFrame(frame, display: true, animate: animated)
    }

    func windowWillClose(_ notification: Notification) {
        // hand focus back to whatever the user was in
        NSApp.hide(nil)
    }
}

struct SettingsView: View {
    enum Tab: Int, CaseIterable, Identifiable {
        case general, speech, advanced
        var id: Int { rawValue }
        var title: String { ["General", "Speech", "Advanced"][rawValue] }
        var symbol: String { ["waveform.and.mic", "globe", "wrench.and.screwdriver"][rawValue] }
    }

    @ObservedObject var model: DictationModel
    @State private var tab: Tab
    let onResize: () -> Void

    init(model: DictationModel, tab: Tab = .general, onResize: @escaping () -> Void = {}) {
        self.model = model
        _tab = State(initialValue: tab)
        self.onResize = onResize
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { t in
                    TabButton(title: t.title, symbol: t.symbol, selected: tab == t) { tab = t }
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 10)
            Divider()
            Group {
                switch tab {
                case .general: GeneralPane(model: model)
                case .speech: SpeechPane(model: model)
                case .advanced: AdvancedPane(model: model)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 22)
        }
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: tab) { _, _ in DispatchQueue.main.async(execute: onResize) }
        .onAppear { DispatchQueue.main.async(execute: onResize) }
    }
}

private struct TabButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .regular))
                    .frame(height: 24)
                Text(title).font(.system(size: 11))
            }
            .frame(width: 76, height: 50)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14) : (hover ? Color.primary.opacity(0.05) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - building blocks (the grouped look of System Settings, sized to content)

private struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).padding(.leading, 2)
            }
            VStack(spacing: 0) { content }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let label: String
    var detail: String? = nil
    var divider = true
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .padding(.vertical, 4)
            if divider { Divider().padding(.leading, 14) }
        }
    }
}

// MARK: - panes

private struct GeneralPane: View {
    @ObservedObject var model: DictationModel
    @State private var wakeDraft = ""
    @State private var commitTask: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Push to talk",
                          footer: "Focus a text field, press the shortcut and speak; the words are typed there. Press it again to stop. The model loads when you start and is released when you stop.") {
                SettingsRow(label: "Shortcut", divider: false) {
                    Text("⌥ Space")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            SettingsGroup(title: "Wake word",
                          footer: "The microphone and the model stay on. Say the phrase to start a segment; it ends by itself after the silence chosen here, or with the shortcut. One or two plain English words the recogniser spells consistently work best. Small recognition errors are tolerated.") {
                SettingsRow(label: "Keep listening for the wake word") {
                    Toggle("", isOn: Binding(get: { model.wakeMode }, set: { model.setWakeMode($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(label: "Phrase") {
                    TextField("hey nemo", text: $wakeDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(commitWakeWord)
                        .onChange(of: wakeDraft) { _, _ in
                            commitTask?.cancel()
                            let task = DispatchWorkItem { commitWakeWord() }
                            commitTask = task
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: task)
                        }
                }
                SettingsRow(label: "End a segment after silence of", divider: false) {
                    Picker("", selection: $model.silenceStop) {
                        ForEach(DictationModel.silenceOptions, id: \.self) { s in Text(String(format: "%.1f s", s)).tag(s) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                }
            }
        }
        .onAppear { wakeDraft = model.wakeWord }
    }

    private func commitWakeWord() {
        let phrase = wakeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !phrase.isEmpty, phrase != model.wakeWord { model.wakeWord = phrase }
    }
}

private struct SpeechPane: View {
    @ObservedObject var model: DictationModel
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Recognition",
                          footer: "Text appears about one chunk behind your speech. 560 ms is the accurate default; 80 ms is snappier but rougher. While waiting for the wake word the recogniser always runs in English at 320 ms; these settings take over once a segment starts.") {
                SettingsRow(label: "Language") {
                    Picker("", selection: $model.language) {
                        ForEach(DictationModel.languages, id: \.0) { code, name in Text(name).tag(code) }
                    }
                    .labelsHidden().frame(width: 190)
                }
                SettingsRow(label: "Chunk latency", divider: false) {
                    Picker("", selection: $model.latencyMs) {
                        ForEach(DictationModel.latencies, id: \.self) { ms in Text("\(ms) ms").tag(ms) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
            }

            SettingsGroup(title: "Microphone",
                          footer: "Remembered by device; if it is not connected the system default is used. Changes apply to the next session or segment.") {
                SettingsRow(label: "Input", divider: false) {
                    HStack(spacing: 8) {
                        Picker("", selection: Binding(get: { model.micUID ?? "" }, set: { model.micUID = $0.isEmpty ? nil : $0 })) {
                            Text("System default" + (AudioInputDevice.systemDefault().map { " · \($0.name)" } ?? "")).tag("")
                            if !devices.isEmpty { Divider() }
                            ForEach(devices, id: \.uid) { d in Text(d.name).tag(d.uid) }
                            if let uid = model.micUID, !devices.contains(where: { $0.uid == uid }) {
                                Text("Not connected").tag(uid)
                            }
                        }
                        .labelsHidden().frame(width: 260)
                        Button { devices = AudioInputDevice.inputs() } label: { Image(systemName: "arrow.clockwise") }
                            .help("Refresh the device list")
                    }
                }
            }
        }
        .onAppear { devices = AudioInputDevice.inputs() }
    }
}

private struct AdvancedPane: View {
    @ObservedObject var model: DictationModel
    @State private var trusted = AXIsProcessTrusted()
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Permissions",
                          footer: "Accessibility access lets NemoDictate type into other apps and find their text cursor. If it says granted but nothing is typed, remove NemoDictate from the list in System Settings and add it again.") {
                SettingsRow(label: "Accessibility", divider: false) {
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Circle().fill(trusted ? Color.green : Color.orange).frame(width: 8, height: 8)
                            Text(trusted ? "Granted" : "Not granted").foregroundStyle(.secondary)
                        }
                        Button("Open System Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }

            SettingsGroup(title: "Diagnostics",
                          footer: "The log records what the recogniser heard while waiting for the wake word, the matcher's decisions and how the text cursor was found in each app. Nothing leaves this Mac.") {
                SettingsRow(label: "Model", detail: "NVIDIA Nemotron 3.5 ASR Streaming 0.6B") {
                    Text(Transcriber.modelSource).foregroundStyle(.secondary)
                }
                SettingsRow(label: "Log", detail: DebugLog.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), divider: false) {
                    HStack(spacing: 8) {
                        Button("Open") { NSWorkspace.shared.open(DebugLog.url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([DebugLog.url]) }
                    }
                }
            }

            SettingsGroup {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NemoDictate").font(.system(size: 13, weight: .semibold))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("Speech recognition in C and Metal, entirely on this Mac.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
            }
        }
        .onReceive(ticker) { _ in trusted = AXIsProcessTrusted() }
        .onAppear { trusted = AXIsProcessTrusted() }
    }
}
