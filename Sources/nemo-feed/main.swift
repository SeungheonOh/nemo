// Headless check of the Swift <-> C bridge: feed an audio file through the library like the app does.
import AVFoundation
import CNemoASR
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else { fputs("usage: nemo-feed file.wav [language] [latency_ms]\n", stderr); exit(2) }
let language = args.count > 2 ? args[2] : "en-US"
let latency = args.count > 3 ? Int32(args[3]) ?? 560 : 560

let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[1]))
let format = file.processingFormat
let frames = AVAudioFrameCount(file.length)
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
try file.read(into: buffer)
let channels = Int(format.channelCount)
var mono = [Float](repeating: 0, count: Int(buffer.frameLength))
for c in 0..<channels {
    let ch = buffer.floatChannelData![c]
    for i in 0..<mono.count { mono[i] += ch[i] / Float(channels) }
}

var err = [CChar](repeating: 0, count: 512)
var dir = [CChar](repeating: 0, count: 1200)
guard nemoasr_default_model_dir(&dir, dir.count) == 0 else { fputs("model not found\n", stderr); exit(1) }
guard let h = nemoasr_open(String(cString: dir), language, latency, Int32(format.sampleRate), &err, err.count) else {
    fputs("open: \(String(cString: err))\n", stderr); exit(1)
}
fputs("[swift] ready in \(Int(nemoasr_load_ms(h))) ms on \(String(cString: nemoasr_gpu_name(h))), input \(Int(format.sampleRate)) Hz\n", stderr)
let block = Int(format.sampleRate) / 10
var pos = 0
while pos < mono.count {
    let n = min(block, mono.count - pos)
    let final = pos + n >= mono.count
    let text = mono.withUnsafeBufferPointer { nemoasr_feed(h, $0.baseAddress! + pos, n, final ? 1 : 0, &err, err.count) }
    if err[0] != 0 { fputs("feed: \(String(cString: err))\n", stderr); exit(1) }
    if let text { print(String(cString: text), terminator: ""); fflush(stdout); nemoasr_free(text) }
    pos += n
}
print()
var st = nemoasr_stats_t()
nemoasr_stats(h, &st)
fputs("[swift] \(String(format: "%.2f", st.audio_seconds))s audio, \(st.chunks) chunks, \(st.tokens) tokens\n", stderr)
nemoasr_close(h)
