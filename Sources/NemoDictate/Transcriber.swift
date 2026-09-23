import AVFoundation
import AudioToolbox
import CNemoASR
import Foundation
import NemoAudio

/// Owns the microphone and the C speech recogniser. All recogniser calls happen on one serial
/// queue; callbacks are delivered on the main queue.
final class Transcriber {
    var onReady: ((String, String) -> Void)?   // GPU name, microphone name
    var onText: ((String, Int) -> Void)?  // newly decoded text (append) and the stream generation it belongs to
    var onLevel: ((Float) -> Void)?       // 0...1 input level
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "nemo.asr", qos: .userInteractive)
    private var handle: OpaquePointer?
    private let engine = AVAudioEngine()
    private var running = false
    private(set) var loadMs: Double = 0
    private var generation = 0          // queue-confined: bumped by every reset
    private var nextGeneration = 0      // main-confined: handed out by reconfigure()

    /// A model shipped inside the app (Contents/Resources/model) wins over the Hugging Face cache.
    static func modelDirectory() -> String? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("model", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("model.safetensors").path) {
            return bundled.path
        }
        var dir = [CChar](repeating: 0, count: 1200)
        return nemoasr_default_model_dir(&dir, dir.count) == 0 ? String(cString: dir) : nil
    }

    static var modelSource: String {
        guard let dir = modelDirectory() else { return "not found" }
        return dir.hasPrefix(Bundle.main.bundlePath) ? "bundled with the app" : "Hugging Face cache"
    }

    /// `deviceUID` nil means the system default input.
    func start(language: String, latencyMs: Int, deviceUID: String?) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.onError?("Microphone access denied. Allow NemoDictate in System Settings > Privacy & Security > Microphone.") }
                return
            }
            self.queue.async { self.open(language: language, latencyMs: latencyMs, deviceUID: deviceUID) }
        }
    }

    /// Route the engine's input unit to a specific CoreAudio device (must happen before start).
    private func selectDevice(_ device: AudioInputDevice) -> Bool {
        guard let unit = engine.inputNode.audioUnit else { return false }
        var id = device.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        return status == noErr
    }

    private func open(language: String, latencyMs: Int, deviceUID: String?) {
        var micName = AudioInputDevice.systemDefault()?.name ?? "default input"
        if let uid = deviceUID {
            if let device = AudioInputDevice.find(uid: uid) {
                if selectDevice(device) { micName = device.name } else { micName = "\(device.name) (could not select, using default)" }
            } else {
                micName = "default input (chosen microphone not connected)"
            }
        }
        let format = engine.inputNode.inputFormat(forBus: 0)
        let rate = Int32(format.sampleRate.rounded())
        guard rate > 0 else { report("No audio input device."); return }
        var err = [CChar](repeating: 0, count: 512)
        guard let dir = Transcriber.modelDirectory() else {
            report("Model not found: neither inside the app nor in the Hugging Face cache (mlx-community/nemotron-3.5-asr-streaming-0.6b).")
            return
        }
        DebugLog.write("model from \(dir)")
        guard let h = nemoasr_open(dir, language, Int32(latencyMs), rate, &err, err.count) else {
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
        DispatchQueue.main.async { self.onReady?(gpu, micName) }
    }

    private func feed(_ samples: [Float], final: Bool) {
        if let s = decode(samples, final: final), !s.isEmpty {
            let gen = generation
            DispatchQueue.main.async { self.onText?(s, gen) }
        }
    }

    /// Queue-confined: run the recogniser and return whatever text it produced.
    private func decode(_ samples: [Float], final: Bool) -> String? {
        guard let h = handle else { return nil }
        var err = [CChar](repeating: 0, count: 512)
        let text = samples.withUnsafeBufferPointer { nemoasr_feed(h, $0.baseAddress, samples.count, final ? 1 : 0, &err, err.count) }
        if err[0] != 0 { report(String(cString: err)) }
        guard let text else { return nil }
        defer { nemoasr_free(text) }
        return String(cString: text)
    }

    /// Start a fresh stream with another language prompt and chunk latency, keeping the microphone
    /// and the loaded model. The audio still buffered is flushed first and its text handed to
    /// `completion` (it belongs to the old stream). Returns the new stream's generation: text tagged
    /// with a lower one was decoded before the switch. Call on the main queue.
    @discardableResult
    func reconfigure(language: String, latencyMs: Int, completion: ((String) -> Void)? = nil) -> Int {
        nextGeneration += 1
        let gen = nextGeneration
        queue.async {
            let tail = self.decode([], final: true) ?? ""
            if let h = self.handle {
                var err = [CChar](repeating: 0, count: 512)
                if nemoasr_reset(h, language, Int32(latencyMs), &err, err.count) != 0 { self.report("Could not restart the stream: \(String(cString: err))") }
            }
            self.generation = gen
            if let completion { DispatchQueue.main.async { completion(tail) } }
        }
        return gen
    }

    /// Compile the kernels for another latency now, so a later `reconfigure` to it is instant.
    func prepare(latencyMs: Int) {
        queue.async {
            guard let h = self.handle else { return }
            var err = [CChar](repeating: 0, count: 512)
            if nemoasr_prepare_latency(h, Int32(latencyMs), &err, err.count) != 0 { self.report(String(cString: err)) }
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
