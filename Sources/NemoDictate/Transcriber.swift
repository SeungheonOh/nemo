import AVFoundation
import CNemoASR
import Foundation

/// Owns the microphone and the C speech recogniser. All recogniser calls happen on one serial
/// queue; callbacks are delivered on the main queue.
final class Transcriber {
    var onReady: ((String) -> Void)?      // GPU name
    var onText: ((String) -> Void)?       // newly decoded text (append)
    var onLevel: ((Float) -> Void)?       // 0...1 input level
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "nemo.asr", qos: .userInteractive)
    private var handle: OpaquePointer?
    private let engine = AVAudioEngine()
    private var running = false
    private(set) var loadMs: Double = 0

    func start(language: String, latencyMs: Int) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.onError?("Microphone access denied. Allow NemoDictate in System Settings > Privacy & Security > Microphone.") }
                return
            }
            self.queue.async { self.open(language: language, latencyMs: latencyMs) }
        }
    }

    private func open(language: String, latencyMs: Int) {
        let format = engine.inputNode.inputFormat(forBus: 0)
        let rate = Int32(format.sampleRate.rounded())
        guard rate > 0 else { report("No audio input device."); return }
        var err = [CChar](repeating: 0, count: 512)
        var dir = [CChar](repeating: 0, count: 1200)
        guard nemoasr_default_model_dir(&dir, dir.count) == 0 else {
            report("Model not found in the Hugging Face cache. Run the Python project once to download mlx-community/nemotron-3.5-asr-streaming-0.6b.")
            return
        }
        guard let h = nemoasr_open(String(cString: dir), language, Int32(latencyMs), rate, &err, err.count) else {
            report("Could not load the model: \(String(cString: err))")
            return
        }
        handle = h
        loadMs = nemoasr_load_ms(h)
        let gpu = String(cString: nemoasr_gpu_name(h))

        // Tap the hardware format (usually 48 kHz, 1–2 channels); the recogniser resamples.
        let channels = Int(format.channelCount)
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            var mono = [Float](repeating: 0, count: frames)
            if channels == 1 {
                mono.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: data[0], count: frames) }
            } else {
                let scale = 1 / Float(channels)
                for c in 0..<channels {
                    let ch = data[c]
                    for i in 0..<frames { mono[i] += ch[i] * scale }
                }
            }
            var sum: Float = 0
            for v in mono { sum += v * v }
            let rms = frames > 0 ? (sum / Float(frames)).squareRoot() : 0
            let level = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 50)) // -50 dBFS..0 dBFS -> 0..1
            DispatchQueue.main.async { self.onLevel?(level) }
            self.queue.async { self.feed(mono, final: false) }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            report("Could not start audio input: \(error.localizedDescription)")
            return
        }
        running = true
        DispatchQueue.main.async { self.onReady?(gpu) }
    }

    private func feed(_ samples: [Float], final: Bool) {
        guard let h = handle else { return }
        var err = [CChar](repeating: 0, count: 512)
        let text = samples.withUnsafeBufferPointer { nemoasr_feed(h, $0.baseAddress, samples.count, final ? 1 : 0, &err, err.count) }
        if err[0] != 0 { report(String(cString: err)) }
        if let text {
            let s = String(cString: text)
            nemoasr_free(text)
            if !s.isEmpty { DispatchQueue.main.async { self.onText?(s) } }
        }
    }

    /// Stops the microphone, flushes the recogniser and releases the model.
    func stop(completion: @escaping () -> Void) {
        if running {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            running = false
        }
        queue.async {
            if self.handle != nil {
                self.feed([], final: true)
                nemoasr_close(self.handle)
                self.handle = nil
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { self.onError?(message) }
    }
}
