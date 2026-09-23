import AppKit
import Combine
import Foundation
import NemoAudio

enum DictationState: Equatable {
    case idle        // nothing running
    case loading     // model loading, mic starting
    case standby     // wake-word mode: listening for the trigger phrase
    case listening   // transcribing
    case finishing   // flushing the decoder
    case done        // result delivered, pill fading out
    case failed
}

enum OutputMode: String { case clipboard, type }

/// UI state for the indicator and the menu bar. Main-thread only.
final class DictationModel: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var level: Float = 0
    @Published var transcript = ""
    @Published var statusLine = ""
    @Published var lastTranscript = ""
    @Published var pillVisible = false

    // settings (persisted)
    @Published var language = UserDefaults.standard.string(forKey: "language") ?? "auto" { didSet { UserDefaults.standard.set(language, forKey: "language") } }
    @Published var latencyMs = UserDefaults.standard.object(forKey: "latencyMs") as? Int ?? 560 { didSet { UserDefaults.standard.set(latencyMs, forKey: "latencyMs") } }
    @Published var micUID: String? = UserDefaults.standard.string(forKey: "micUID") { didSet { UserDefaults.standard.set(micUID, forKey: "micUID") } }
    @Published var outputMode = OutputMode(rawValue: UserDefaults.standard.string(forKey: "outputMode") ?? "") ?? .clipboard { didSet { UserDefaults.standard.set(outputMode.rawValue, forKey: "outputMode") } }
    @Published var wakeWord = UserDefaults.standard.string(forKey: "wakeWord") ?? "hey nemo" { didSet { UserDefaults.standard.set(wakeWord, forKey: "wakeWord"); detector = WakeWordDetector(phrase: wakeWord) } }
    @Published var wakeMode = UserDefaults.standard.bool(forKey: "wakeMode") { didSet { UserDefaults.standard.set(wakeMode, forKey: "wakeMode") } }
    @Published var silenceStop = UserDefaults.standard.object(forKey: "silenceStop") as? Double ?? 2.5 { didSet { UserDefaults.standard.set(silenceStop, forKey: "silenceStop") } }

    var onStateChange: ((DictationState) -> Void)?
    private var transcriber: Transcriber?
    private var detector: WakeWordDetector
    private var hideTask: DispatchWorkItem?
    private var silenceTask: DispatchWorkItem?
    private var typedCount = 0          // characters of `transcript` already typed into the focused app

    static let languages: [(String, String)] = [
        ("auto", "Detect language"), ("en-US", "English"), ("ko-KR", "Korean"), ("ja-JP", "Japanese"),
        ("de-DE", "German"), ("fr-FR", "French"), ("es-ES", "Spanish"), ("zh-CN", "Chinese"),
    ]
    static let latencies = [80, 320, 560, 1120]
    static let silenceOptions: [Double] = [1.5, 2.5, 4.0]

    init() {
        detector = WakeWordDetector(phrase: UserDefaults.standard.string(forKey: "wakeWord") ?? "hey nemo")
    }

    var isRunning: Bool { transcriber != nil }

    // MARK: - Commands

    /// Hotkey / menu: push-to-talk toggles the whole session; in wake mode it toggles transcription.
    func toggle() {
        switch state {
        case .idle, .done, .failed: start()
        case .standby: beginTranscribing(initial: "")
        case .listening: finishTranscribing()
        case .loading, .finishing: break
        }
    }

    func setWakeMode(_ on: Bool) {
        wakeMode = on
        if on {
            if state == .idle || state == .done || state == .failed { start() }
        } else if state == .standby || state == .done, isRunning {
            shutdown(then: .idle)
        }
    }

    func setOutputMode(_ mode: OutputMode) {
        if mode == .type, !TextInserter.isTrusted {
            TextInserter.requestTrust()
            statusLine = "Grant Accessibility access to NemoDictate, then pick this again"
            flash()
            return
        }
        outputMode = mode
    }

    func copyLast() {
        guard !lastTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    // MARK: - Session

    func start() {
        hideTask?.cancel()
        transcript = ""
        typedCount = 0
        level = 0
        detector.reset()
        statusLine = "Loading model…"
        set(.loading)
        let t = Transcriber()
        transcriber = t
        t.onReady = { [weak self] gpu, mic in
            guard let self, self.state == .loading else { return }
            if self.wakeMode {
                self.statusLine = "Say “\(self.wakeWord)” to start · \(mic)"
                self.set(.standby)
                self.scheduleHide(after: 2.5)
            } else {
                self.statusLine = "Listening · \(mic) · \(self.latencyMs) ms · \(Int(t.loadMs)) ms load · \(gpu)"
                self.set(.listening)
            }
        }
        t.onText = { [weak self] text in self?.handleText(text) }
        t.onLevel = { [weak self] l in self?.level = l }
        t.onError = { [weak self] message in
            guard let self else { return }
            self.statusLine = message
            self.set(.failed)
            self.transcriber?.stop {}
            self.transcriber = nil
            self.scheduleHide(after: 6)
        }
        t.start(language: language, latencyMs: latencyMs, deviceUID: micUID)
    }

    private func handleText(_ text: String) {
        switch state {
        case .standby, .done:
            // in wake mode the mic keeps running through the "done" notice, so the phrase can re-trigger right away
            guard wakeMode, isRunning else { return }
            if let after = detector.feed(text) { beginTranscribing(initial: after) }
        case .listening:
            transcript += text
            deliverLiveText()
            if wakeMode { armSilenceTimer() }
        default:
            break
        }
    }

    private func beginTranscribing(initial: String) {
        hideTask?.cancel()
        transcript = initial.isEmpty ? "" : initial.prefix(1).uppercased() + initial.dropFirst()
        typedCount = 0
        let target = outputMode == .type ? " · typing into \(TextInserter.frontmostAppName)" : ""
        statusLine = "Transcribing\(target) · stops after \(String(format: "%.1f", silenceStop)) s of silence"
        set(.listening)
        deliverLiveText()
        armSilenceTimer()
    }

    /// Push-to-talk stop, or wake mode: end of one dictation segment.
    func stop() { finishTranscribing() }

    private func finishTranscribing() {
        guard state == .listening, let t = transcriber else { return }
        silenceTask?.cancel()
        statusLine = "Finishing…"
        set(.finishing)
        if wakeMode {
            // keep the microphone and the model running: just deliver this segment
            deliverFinal()
            set(.done)
            detector.reset()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.state == .done else { return }
                self.transcript = ""
                self.statusLine = "Say “\(self.wakeWord)” to start"
                self.set(.standby)
                self.scheduleHide(after: 1.5)
            }
        } else {
            t.stop { [weak self] in
                guard let self else { return }
                self.transcriber = nil
                self.deliverFinal()
                self.set(.done)
                self.scheduleHide(after: 1.6)
            }
        }
    }

    private func shutdown(then next: DictationState) {
        silenceTask?.cancel()
        hideTask?.cancel()
        let t = transcriber
        transcriber = nil
        set(next)
        t?.stop {}
    }

    // MARK: - Output

    private func deliverLiveText() {
        guard outputMode == .type, TextInserter.isTrusted else { return }
        let pending = String(transcript.dropFirst(typedCount))
        if !pending.isEmpty {
            TextInserter.type(pending)
            typedCount = transcript.count
        }
    }

    private func deliverFinal() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { statusLine = "Nothing heard"; return }
        lastTranscript = text
        switch outputMode {
        case .clipboard:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            statusLine = "Copied to clipboard"
        case .type:
            if TextInserter.isTrusted {
                deliverLiveText()
                statusLine = "Inserted into \(TextInserter.frontmostAppName)"
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                statusLine = "No Accessibility access · copied to clipboard instead"
            }
        }
    }

    // MARK: - Timers

    private func armSilenceTimer() {
        guard wakeMode else { return }
        silenceTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.state == .listening else { return }
            self.finishTranscribing()
        }
        silenceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + silenceStop, execute: task)
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.state == .done || self.state == .failed { self.set(self.wakeMode && self.isRunning ? .standby : .idle) }
            self.pillVisible = false
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    private func flash() {
        pillVisible = true
        scheduleHide(after: 4)
    }

    private func set(_ s: DictationState) {
        state = s
        pillVisible = s != .idle
        onStateChange?(s)
    }
}
