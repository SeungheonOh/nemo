import Foundation

/// Appends short lines to ~/Library/Logs/NemoDictate.log so problems in other apps (where the caret
/// lookup happens) can be read afterwards. Truncated when it grows past a megabyte.
enum DebugLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NemoDictate.log")
    private static let queue = DispatchQueue(label: "dev.nemo.log", qos: .utility)
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    static func write(_ line: String) {
        let text = "\(stamp.string(from: Date())) \(line)\n"
        queue.async {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), (attrs[.size] as? Int ?? 0) > 1_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); try? h.close()
            } else {
                try? text.data(using: .utf8)!.write(to: url)
            }
        }
    }
}
