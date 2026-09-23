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
    @Published var caretEffectVisible = false   // typing mode: the glow that follows the insertion point
    @Published var insertPulse = 0              // bumps every time a chunk of text is typed
    private let demo = ProcessInfo.processInfo.environment["NEMO_DEMO"]   // "pill" / "caret": drive the UI without a microphone

    // settings (persisted)
    @Published var language = UserDefaults.standard.string(forKey: "language") ?? "auto" { didSet { UserDefaults.standard.set(language, forKey: "language") } }
    @Published var latencyMs = UserDefaults.standard.object(forKey: "latencyMs") as? Int ?? 560 { didSet { UserDefaults.standard.set(latencyMs, forKey: "latencyMs") } }
    @Published var micUID: String? = UserDefaults.standard.string(forKey: "micUID") { didSet { UserDefaults.standard.set(micUID, forKey: "micUID") } }
    @Published var outputMode = OutputMode(rawValue: UserDefaults.standard.string(forKey: "outputMode") ?? "") ?? .clipboard { didSet { UserDefaults.standard.set(outputMode.rawValue, forKey: "outputMode"); updateOverlays() } }
    @Published var wakeWord = UserDefaults.standard.string(forKey: "wakeWord") ?? "hey nemo" { didSet { UserDefaults.standard.set(wakeWord, forKey: "wakeWord"); detector = WakeWordDetector(phrase: wakeWord) } }
    @Published var wakeMode = UserDefaults.standard.bool(forKey: "wakeMode") { didSet { UserDefaults.standard.set(wakeMode, forKey: "wakeMode") } }
    @Published var silenceStop = UserDefaults.standard.object(forKey: "silenceStop") as? Double ?? 2.5 { didSet { UserDefaults.standard.set(silenceStop, forKey: "silenceStop") } }

    var onStateChange: ((DictationState) -> Void)?
    private var transcriber: Transcriber?
    private var detector: WakeWordDetector
    private var hideTask: DispatchWorkItem?
    private var silenceTask: DispatchWorkItem?
    private var wakePendingTask: DispatchWorkItem?
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
            TextInserter.requestTrust()   // the system prompt; typing falls back to the clipboard until it is granted
            statusLine = "Grant Accessibility access to NemoDictate for typing"
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
        warnIfUntrusted()
        let t = Transcriber()
        transcriber = t
        t.onReady = { [weak self] gpu, mic in
            guard let self, self.state == .loading else { return }
            if self.wakeMode {
                t.prepare(latencyMs: self.latencyMs)   // dictation kernels ready before the first switch
                self.statusLine = "Say “\(self.wakeWord)” to start · \(mic)"
                self.set(.standby)
                self.scheduleHide(after: 2.5)
            } else {
                self.statusLine = "Listening · \(mic) · \(self.latencyMs) ms · \(Int(t.loadMs)) ms load · \(gpu)"
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
            self.scheduleHide(after: 6)
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
            // in wake mode the mic keeps running through the "done" notice, so the phrase can re-trigger right away
            guard wakeMode, isRunning else { return }
            wakePendingTask?.cancel()
            if let after = detector.feed(text) {
                beginTranscribing(initial: after)
            } else if detector.hasPending {
                // "spar" arrived at the end of a chunk: give the "k" half a second to show up
                let task = DispatchWorkItem { [weak self] in
                    guard let self, self.state == .standby || self.state == .done else { return }
                    if let after = self.detector.flushPending() { self.beginTranscribing(initial: after) }
                }
                wakePendingTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
            }
        case .listening:
            if transcript.isEmpty {
                // the first dictated chunk starts a new word; anything glued to the wake word, or bare
                // punctuation that belonged to it, is not dictation
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let glued = text.first.map { $0.isLetter || $0.isNumber } ?? false
                let hasWord = trimmed.contains(where: { $0.isLetter || $0.isNumber })
                if wakeMode, glued || !hasWord { return }
            }
            transcript += text
            deliverLiveText()
            if wakeMode { armSilenceTimer() }
        default:
            break
        }
    }

    private func beginTranscribing(initial: String) {
        hideTask?.cancel()
        wakePendingTask?.cancel()
        if wakeMode, let t = transcriber {
            // leave the English wake stream for the dictation language and latency; whatever the wake
            // stream still had buffered is the wake word's tail, so it is dropped
            acceptGeneration = t.reconfigure(language: language, latencyMs: latencyMs)
        }
        transcript = initial.isEmpty ? "" : initial.prefix(1).uppercased() + initial.dropFirst()
        typedCount = 0
        let target = outputMode == .type ? " · typing into \(TextInserter.frontmostAppName)" : ""
        statusLine = "Transcribing\(target) · stops after \(String(format: "%.1f", silenceStop)) s of silence"
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
                    if self.outputMode == .type { self.deliverLiveText() }
                }
                self.deliverFinal()
                self.set(.done)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self, self.state == .done else { return }
                    self.transcript = ""
                    self.statusLine = "Say “\(self.wakeWord)” to start"
                    self.set(.standby)
                    self.scheduleHide(after: 1.5)
                }
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
            insertPulse += 1
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

    // MARK: - Demo (NEMO_DEMO=1: drives the pill without a microphone, for UI work)

    func demoStream() {
        statusLine = "Listening · demo · 560 ms"
        set(.listening)
        if demo == "caret" {
            // fake typing bursts and a finish, so the caret effect can be looked at without a text field
            Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] t in
                guard let self, self.state == .listening else { t.invalidate(); return }
                self.insertPulse += 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in
                guard let self else { return }
                self.statusLine = "Inserted"
                self.set(.done)
                self.scheduleHide(after: 1.6)
            }
        }
        let words = """
        The quick brown fox jumps over the lazy dog while the indicator keeps growing line by line, \
        so that a longer dictation stays readable instead of being cut off after two lines. Once it reaches \
        about ten lines it stops growing and scrolls, keeping the newest words at the bottom where the eye \
        expects them, and the status line stays put underneath the text the whole time. This sentence is \
        here to push it past the limit so the scrolling behaviour can be checked as well, and then some more \
        words follow so that the oldest lines have to leave through the top while the latest ones stay in view.
        """.split(separator: " ").map(String.init)
        var i = 0
        Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] t in
            guard let self, i < words.count else { t.invalidate(); return }
            self.transcript += (i == 0 ? "" : " ") + words[i]
            self.level = Float.random(in: 0.2...0.9)
            i += 1
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

    /// Typing mode without Accessibility access would silently do nothing: ask the system to prompt,
    /// and leave the reason in the status line (visible in the menu) and the log. No pill in this mode.
    private func warnIfUntrusted() {
        guard outputMode == .type, demo == nil else { return }
        DebugLog.write("typing session · trusted \(TextInserter.isTrusted) · target \(TextInserter.frontmostAppName)")
        guard !TextInserter.isTrusted else { return }
        TextInserter.requestTrust()
        statusLine = "Accessibility access is off for NemoDictate · Privacy & Security → Accessibility"
    }

    /// When typing straight into the focused field the text itself is the feedback, so the pill stays
    /// hidden and the caret glow is shown instead; failures still use the pill.
    private var typingMode: Bool { demo == "caret" || (demo != "pill" && outputMode == .type) }

    private func updateOverlays() {
        // typing mode never shows the pill: the text arriving in the field, the caret glow and the
        // menu-bar icon are the feedback
        pillVisible = !typingMode && state != .idle
        switch state {
        case .idle, .failed, .standby:
            caretEffectVisible = false
        case .loading, .listening, .finishing:
            caretEffectVisible = typingMode
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
        onStateChange?(s)
    }
}
