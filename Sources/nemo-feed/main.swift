// Headless check of the Swift <-> C bridge: feed an audio file through the library like the app does.
import AVFoundation
import CNemoASR
import Foundation
import NemoAudio

let args = CommandLine.arguments
if args.count >= 2, args[1] == "--list-mics" {
    let dflt = AudioInputDevice.systemDefault()
    for d in AudioInputDevice.inputs() {
        print("\(d.id == dflt?.id ? ">" : " ") \(d.name)  [\(d.uid)]  \(Int(d.sampleRate)) Hz, \(d.inputChannels) ch")
    }
    exit(0)
}
if args.count >= 2, args[1] == "--wake-test" {
    var det = WakeWordDetector(phrase: args.count > 2 ? args[2] : "hey nemo")
    // chunks as the recogniser emits them: a leading space starts a word, no space continues one
    let stream: [String] = args.count > 2 && args[2].lowercased() == "spark"
        ? [" Spar", "k", " write this down", " Spar", "k.", " Spark", " open the file", " spar", "<pause>", " so", " Spar", "row is a bird", " sparks fly", "<pause>"]
        : [" so I was thinking", " about lunch. Hey Nimo,", " open the window please", " hey nemo", " what time is it",
           " heynemo", " hey memo turn it off", " hey", " ne", "mo write this down", " hey nemesis", " a demo", " hey ne", "<pause>"]
    for chunk in stream {
        let r = chunk == "<pause>" ? det.flushPending() : det.feed(chunk)
        let state = det.hasPending ? " (holding)" : ""
        print("\(chunk.debugDescription.padding(toLength: 28, withPad: " ", startingAt: 0)) -> \(r.map { "TRIGGER, after: \"\($0)\"" } ?? "-")\(state)")
    }
    exit(0)
}
guard args.count >= 2 else { fputs("usage: nemo-feed file.wav [language] [latency_ms] | --list-mics | --wake-test [phrase]\n", stderr); exit(2) }
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
