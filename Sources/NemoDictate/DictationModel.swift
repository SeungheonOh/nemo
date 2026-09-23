import AppKit
import Combine
import Foundation

enum DictationState: Equatable {
    case idle, loading, listening, finishing, done, failed
}

/// UI state for the indicator and the menu bar. Main-thread only.
final class DictationModel: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var level: Float = 0
    @Published var transcript = ""
    @Published var statusLine = ""
    @Published var lastTranscript = ""
    @Published var language = UserDefaults.standard.string(forKey: "language") ?? "auto" {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    @Published var latencyMs = UserDefaults.standard.object(forKey: "latencyMs") as? Int ?? 560 {
        didSet { UserDefaults.standard.set(latencyMs, forKey: "latencyMs") }
    }

    var onStateChange: ((DictationState) -> Void)?
    private var transcriber: Transcriber?
    private var startedAt = Date()
    private var hideTask: DispatchWorkItem?

    static let languages: [(String, String)] = [
        ("auto", "Detect language"), ("en-US", "English"), ("ko-KR", "Korean"), ("ja-JP", "Japanese"),
        ("de-DE", "German"), ("fr-FR", "French"), ("es-ES", "Spanish"), ("zh-CN", "Chinese"),
    ]
    static let latencies = [80, 320, 560, 1120]

    var isActive: Bool { state == .loading || state == .listening || state == .finishing }

    func toggle() {
        switch state {
        case .idle, .done, .failed: start()
        case .listening: stop()
        case .loading, .finishing: break
        }
    }

    func start() {
        hideTask?.cancel()
        transcript = ""
        level = 0
        statusLine = "Loading model…"
        set(.loading)
        let t = Transcriber()
        transcriber = t
        t.onReady = { [weak self] gpu in
            guard let self, self.state == .loading else { return }
            self.startedAt = Date()
            self.statusLine = "Listening · \(self.latencyMs) ms · \(Int(t.loadMs)) ms load · \(gpu)"
            self.set(.listening)
        }
        t.onText = { [weak self] text in
            guard let self else { return }
            self.transcript += text
        }
        t.onLevel = { [weak self] l in self?.level = l }
        t.onError = { [weak self] message in
            guard let self else { return }
            self.statusLine = message
            self.set(.failed)
            self.transcriber?.stop {}
            self.transcriber = nil
            self.scheduleHide(after: 6)
        }
        t.start(language: language, latencyMs: latencyMs)
    }

    func stop() {
        guard state == .listening, let t = transcriber else { return }
        statusLine = "Finishing…"
        set(.finishing)
        t.stop { [weak self] in
            guard let self else { return }
            let text = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            self.transcriber = nil
            if text.isEmpty {
                self.statusLine = "Nothing heard"
            } else {
                self.lastTranscript = text
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.statusLine = "Copied to clipboard"
            }
            self.set(.done)
            self.scheduleHide(after: 1.6)
        }
    }

    func copyLast() {
        guard !lastTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.state == .done || self.state == .failed else { return }
            self.set(.idle)
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    private func set(_ s: DictationState) {
        state = s
        onStateChange?(s)
    }
}
