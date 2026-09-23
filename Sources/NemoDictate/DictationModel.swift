import AppKit
import Combine
import Foundation
import NemoAudio

enum DictationState: Equatable {
    case idle        // nothing running
    case loading     // model loading, mic starting
    case standby     // wake-word mode: listening for the trigger phrase
    case listening   // transcribing into the focused field
    case finishing   // flushing the decoder
    case done        // segment delivered
    case failed
}

/// The app's state machine. Recognised text is typed straight into whatever has keyboard focus; the
/// only visible feedback is the glow on that field's caret and the menu-bar icon. Main-thread only.
final class DictationModel: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var level: Float = 0
    @Published var transcript = ""
    @Published var statusLine = ""
    @Published var lastTranscript = ""
    @Published var caretEffectVisible = false   // the glow that follows the insertion point
    @Published var insertPulse = 0              // bumps every time a chunk of text is typed
    private let demo = ProcessInfo.processInfo.environment["NEMO_DEMO"]   // "caret": drive the glow without a microphone

    // settings (persisted)
    @Published var language = UserDefaults.standard.string(forKey: "language") ?? "auto" { didSet { UserDefaults.standard.set(language, forKey: "language") } }
    @Published var latencyMs = UserDefaults.standard.object(forKey: "latencyMs") as? Int ?? 560 { didSet { UserDefaults.standard.set(latencyMs, forKey: "latencyMs") } }
    @Published var micUID: String? = UserDefaults.standard.string(forKey: "micUID") { didSet { UserDefaults.standard.set(micUID, forKey: "micUID") } }
    @Published var wakeWord = UserDefaults.standard.string(forKey: "wakeWord") ?? "hey nemo" { didSet { UserDefaults.standard.set(wakeWord, forKey: "wakeWord"); detector = WakeWordDetector(phrase: wakeWord) } }
    @Published var wakeMode = UserDefaults.standard.bool(forKey: "wakeMode") { didSet { UserDefaults.standard.set(wakeMode, forKey: "wakeMode") } }
    @Published var silenceStop = UserDefaults.standard.object(forKey: "silenceStop") as? Double ?? 2.5 { didSet { UserDefaults.standard.set(silenceStop, forKey: "silenceStop") } }

    private var transcriber: Transcriber?
    private var detector: WakeWordDetector
    private var settleTask: DispatchWorkItem?
    private var silenceTask: DispatchWorkItem?
    private var wakePendingTask: DispatchWorkItem?
    private var standbyRefreshTask: DispatchWorkItem?
    private var acceptGeneration = 0    // text from older recogniser streams (before a switch) is ignored
    private var typedCount = 0          // characters of `transcript` already typed into the focused app

    static let languages: [(String, String)] = [
        ("auto", "Detect language"), ("en-US", "English"), ("ko-KR", "Korean"), ("ja-JP", "Japanese"),
        ("de-DE", "German"), ("fr-FR", "French"), ("es-ES", "Spanish"), ("zh-CN", "Chinese"),
    ]
    static let latencies = [80, 320, 560, 1120]
    /// Standby listens in English at a short chunk, whatever the dictation language: the wake word is
    /// English and a short chunk makes the trigger snappy. Each segment switches to the chosen language
    /// and latency, and back afterwards, so speech in another language never has to "wear off" first.
    static let wakeLanguage = "en-US"
    static let wakeLatencyMs = 320
    /// After this long without a word, and while the room is quiet, the wake stream is restarted so it
    /// never sits on a long history of silence when the trigger finally comes.
    static let standbyRefreshSeconds = 15.0
    static let silenceOptions: [Double] = [1.5, 2.5, 4.0]

    init() {
        detector = WakeWordDetector(phrase: UserDefaults.standard.string(forKey: "wakeWord") ?? "hey nemo")
    }

    var isRunning: Bool { transcriber != nil }

    // MARK: - Commands

    /// Hotkey / menu: push-to-talk toggles the whole session; in wake mode it toggles a segment.
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

    func copyLast() {
        guard !lastTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    // MARK: - Session

    func start() {
        settleTask?.cancel()
        transcript = ""
        typedCount = 0
        level = 0
        detector.reset()
        statusLine = "Loading model…"
        set(.loading)
        warnIfUntrusted()
        let t = Transcriber()
        transcriber = t
        t.onReady = { [weak self] gpu, mic in
            guard let self, self.state == .loading else { return }
            if self.wakeMode {
                t.prepare(latencyMs: self.latencyMs)   // dictation kernels ready before the first switch
                self.statusLine = "Standing by for “\(self.wakeWord)” · \(mic)"
                self.set(.standby)
                self.armStandbyRefresh()
            } else {
                self.statusLine = "Transcribing into \(TextInserter.frontmostAppName) · \(mic) · \(self.latencyMs) ms · \(Int(t.loadMs)) ms load · \(gpu)"
                self.set(.listening)
            }
        }
        t.onText = { [weak self] text, gen in self?.handleText(text, generation: gen) }
        t.onLevel = { [weak self] l in self?.level = l }
        t.onError = { [weak self] message in
            guard let self else { return }
            DebugLog.write("failed: \(message)")
            self.statusLine = message
            self.set(.failed)
            self.transcriber?.stop {}
            self.transcriber = nil
            self.settle(after: 6)
        }
        acceptGeneration = 0
        if wakeMode {
            t.start(language: Self.wakeLanguage, latencyMs: Self.wakeLatencyMs, deviceUID: micUID)
        } else {
            t.start(language: language, latencyMs: latencyMs, deviceUID: micUID)
        }
    }

    private func handleText(_ text: String, generation: Int) {
        guard generation >= acceptGeneration else { return }   // decoded before the last stream switch
        switch state {
        case .standby, .done:
            // in wake mode the mic keeps running through the "done" moment, so the phrase can re-trigger right away
            guard wakeMode, isRunning else { return }
            wakePendingTask?.cancel()
            armStandbyRefresh()   // there was speech: leave the stream alone for a while
            let result = detector.feed(text)
            DebugLog.write("standby heard \(text.debugDescription) → \(result.map { "TRIGGER, after \($0.debugDescription)" } ?? (detector.hasPending ? "holding" : "-"))")
            if let after = result {
                beginTranscribing(initial: after)
            } else if detector.hasPending {
                // "spar" arrived at the end of a chunk: give the "k" a moment to show up
                let task = DispatchWorkItem { [weak self] in
                    guard let self, self.state == .standby || self.state == .done else { return }
                    if let after = self.detector.flushPending() {
                        DebugLog.write("standby held word accepted → TRIGGER")
                        self.beginTranscribing(initial: after)
                    }
                }
                wakePendingTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
            }
        case .listening:
            transcript += text
            deliverLiveText()
            if wakeMode { armSilenceTimer() }
        default:
            break
        }
    }

    private func beginTranscribing(initial: String) {
        settleTask?.cancel()
        wakePendingTask?.cancel()
        standbyRefreshTask?.cancel()
        if wakeMode, let t = transcriber {
            // leave the English wake stream for the dictation language and latency; whatever the wake
            // stream still had buffered is the wake word's tail, so it is dropped
            acceptGeneration = t.reconfigure(language: language, latencyMs: latencyMs)
        }
        DebugLog.write("segment start · initial \(initial.debugDescription) · into \(TextInserter.frontmostAppName)")
        transcript = initial.isEmpty ? "" : initial.prefix(1).uppercased() + initial.dropFirst()
        typedCount = 0
        let stop = wakeMode ? " · stops after \(String(format: "%.1f", silenceStop)) s of silence" : ""
        statusLine = "Transcribing into \(TextInserter.frontmostAppName)\(stop)"
        set(.listening)
        warnIfUntrusted()
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
            // keep the microphone and the model running: flush this segment's last words, deliver it,
            // and go back to the English wake stream
            detector.reset()
            acceptGeneration = t.reconfigure(language: Self.wakeLanguage, latencyMs: Self.wakeLatencyMs) { [weak self] tail in
                guard let self else { return }
                if !tail.isEmpty {
                    self.transcript += tail
                    self.deliverLiveText()
                }
                self.deliverFinal()
                self.set(.done)
                DebugLog.write("segment end · \(self.transcript.count) characters")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self, self.state == .done else { return }
                    self.transcript = ""
                    self.statusLine = "Standing by for “\(self.wakeWord)”"
                    self.set(.standby)
                    self.armStandbyRefresh()
                }
            }
        } else {
            t.stop { [weak self] in
                guard let self else { return }
                self.transcriber = nil
                self.deliverFinal()
                self.set(.done)
                self.settle(after: 1.0)
            }
        }
    }

    private func shutdown(then next: DictationState) {
        silenceTask?.cancel()
        settleTask?.cancel()
        standbyRefreshTask?.cancel()
        wakePendingTask?.cancel()
        let t = transcriber
        transcriber = nil
        set(next)
        t?.stop {}
    }

    // MARK: - Output

    private func deliverLiveText() {
        guard TextInserter.isTrusted else { return }
        let pending = String(transcript.dropFirst(typedCount))
        if !pending.isEmpty {
            TextInserter.type(pending)
            typedCount = transcript.count
            insertPulse += 1
        }
    }

    private func deliverFinal() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { statusLine = "Nothing heard"; return }
        lastTranscript = text
        if TextInserter.isTrusted {
            deliverLiveText()
            statusLine = "Inserted into \(TextInserter.frontmostAppName)"
        } else {
            // without Accessibility nothing can be typed: at least the text is not lost
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            statusLine = "No Accessibility access · copied to the clipboard instead"
        }
    }

    /// Typing without Accessibility access would silently do nothing: ask the system to prompt, and
    /// leave the reason in the status line (visible in the menu) and the log.
    private func warnIfUntrusted() {
        guard demo == nil else { return }
        DebugLog.write("session · trusted \(TextInserter.isTrusted) · target \(TextInserter.frontmostAppName)")
        guard !TextInserter.isTrusted else { return }
        TextInserter.requestTrust()
        statusLine = "Accessibility access is off for NemoDictate · Privacy & Security → Accessibility"
    }

    // MARK: - Demo (NEMO_DEMO=caret: drives the glow without a microphone, for UI work)

    func demoCaret() {
        statusLine = "Transcribing · demo"
        set(.listening)
        Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] t in
            guard let self, self.state == .listening else { t.invalidate(); return }
            self.insertPulse += 1
            self.level = Float.random(in: 0.2...0.9)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in
            guard let self else { return }
            self.statusLine = "Inserted"
            self.set(.done)
            self.settle(after: 1.6)
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

    /// Restart the wake stream after a long quiet spell, but never over someone talking.
    private func armStandbyRefresh(after seconds: Double = DictationModel.standbyRefreshSeconds) {
        standbyRefreshTask?.cancel()
        guard wakeMode else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.state == .standby, self.isRunning, let t = self.transcriber else { return }
            if self.level < 0.12 {
                self.acceptGeneration = t.reconfigure(language: Self.wakeLanguage, latencyMs: Self.wakeLatencyMs)
                self.detector.reset()
                DebugLog.write("standby stream refreshed after \(Int(seconds)) s of quiet")
                self.armStandbyRefresh()
            } else {
                self.armStandbyRefresh(after: 3)
            }
        }
        standbyRefreshTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    /// After a segment or a failure, drop back to standby (wake mode) or idle.
    private func settle(after seconds: Double) {
        settleTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.state == .done || self.state == .failed else { return }
            self.set(self.wakeMode && self.isRunning ? .standby : .idle)
        }
        settleTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    private func updateOverlays() {
        switch state {
        case .idle, .failed, .standby:
            caretEffectVisible = false
        case .loading, .listening, .finishing:
            caretEffectVisible = true
        case .done:
            // the caret glow lingers for a moment, then goes
            if caretEffectVisible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, self.state != .listening, self.state != .loading else { return }
                    self.caretEffectVisible = false
                }
            }
        }
    }

    private func set(_ s: DictationState) {
        state = s
        updateOverlays()
    }
}
