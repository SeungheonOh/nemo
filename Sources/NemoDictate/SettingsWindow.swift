import AppKit
import ApplicationServices
import NemoAudio
import SwiftUI

/// The settings window: a titled window hosting the SwiftUI form. The app is menu-bar only, so the
/// window activates the app while open.
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(model: DictationModel) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "NemoDictate Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(NSSize(width: 520, height: 440))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // hand focus back to whatever the user was in
        NSApp.hide(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: DictationModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "waveform") }
            SpeechSettings(model: model)
                .tabItem { Label("Speech", systemImage: "globe") }
            AdvancedSettings(model: model)
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 520, height: 440)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: DictationModel
    @State private var wakeDraft = ""
    @State private var commitTask: DispatchWorkItem?

    var body: some View {
        Form {
            Section {
                LabeledContent("Start and stop") { Text("Option + Space").foregroundStyle(.secondary) }
                Text("Press with a text field focused; what you say is typed there. Press again to stop.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Push to talk") }

            Section {
                Toggle("Keep listening for a wake word", isOn: Binding(get: { model.wakeMode }, set: { model.setWakeMode($0) }))
                TextField("Wake word", text: $wakeDraft, prompt: Text("hey nemo"))
                    .onSubmit(commitWakeWord)
                    .onChange(of: wakeDraft) { _, _ in
                        commitTask?.cancel()
                        let task = DispatchWorkItem { commitWakeWord() }
                        commitTask = task
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: task)
                    }
                Picker("Stop after silence", selection: $model.silenceStop) {
                    ForEach(DictationModel.silenceOptions, id: \.self) { s in Text(String(format: "%.1f s", s)).tag(s) }
                }
                Text("The microphone and the model stay on. Say the wake word to dictate; the segment ends by itself after the silence above, or press Option + Space. One or two plain words the recogniser spells consistently work best; small recognition errors are tolerated.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Wake word") }
        }
        .formStyle(.grouped)
        .onAppear { wakeDraft = model.wakeWord }
    }

    private func commitWakeWord() {
        let phrase = wakeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !phrase.isEmpty, phrase != model.wakeWord { model.wakeWord = phrase }
    }
}

private struct SpeechSettings: View {
    @ObservedObject var model: DictationModel
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $model.language) {
                    ForEach(DictationModel.languages, id: \.0) { code, name in Text("\(name) (\(code))").tag(code) }
                }
                Picker("Chunk latency", selection: $model.latencyMs) {
                    ForEach(DictationModel.latencies, id: \.self) { ms in Text("\(ms) ms").tag(ms) }
                }
                Text("Text appears about one chunk behind your speech. 560 ms is the accurate default; 80 ms is snappier but rougher. Wake-word listening always runs in English at 320 ms; these two apply once a segment starts.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Recognition") }

            Section {
                Picker("Input", selection: Binding(get: { model.micUID ?? "" }, set: { model.micUID = $0.isEmpty ? nil : $0 })) {
                    Text("System default" + (AudioInputDevice.systemDefault().map { " (\($0.name))" } ?? "")).tag("")
                    ForEach(devices, id: \.uid) { d in Text("\(d.name)  ·  \(Int(d.sampleRate)) Hz, \(d.inputChannels) ch").tag(d.uid) }
                    if let uid = model.micUID, !devices.contains(where: { $0.uid == uid }) {
                        Text("Chosen microphone not connected").tag(uid)
                    }
                }
                HStack {
                    Text("Changes apply to the next session or segment.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { devices = AudioInputDevice.inputs() }
                }
            } header: { Text("Microphone") }
        }
        .formStyle(.grouped)
        .onAppear { devices = AudioInputDevice.inputs() }
    }
}

private struct AdvancedSettings: View {
    @ObservedObject var model: DictationModel
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section {
                LabeledContent("Accessibility access") {
                    Text(trusted ? "Granted" : "Not granted").foregroundStyle(trusted ? Color.green : Color.orange)
                }
                Text("Needed to type into other apps and to find their text cursor. If it says granted but nothing is typed, remove NemoDictate from the Accessibility list and add it again.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Accessibility Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
                }
            } header: { Text("Permissions") }

            Section {
                LabeledContent("Model") { Text(Transcriber.modelSource).foregroundStyle(.secondary) }
                LabeledContent("Log") {
                    Button("Open Log") { NSWorkspace.shared.open(DebugLog.url) }
                }
                Text("The log records what the recogniser heard while standing by, the matcher's decisions, and how the text cursor was found in each app. Nothing is sent anywhere.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Diagnostics") }

            Section {
                LabeledContent("Version") {
                    Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"))")
                        .foregroundStyle(.secondary)
                }
                Text("NVIDIA Nemotron 3.5 ASR Streaming 0.6B, running on this Mac in C and Metal.").font(.callout).foregroundStyle(.secondary)
            } header: { Text("About") }
        }
        .formStyle(.grouped)
        .onAppear { trusted = AXIsProcessTrusted() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in trusted = AXIsProcessTrusted() }
    }
}
