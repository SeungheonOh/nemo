import Foundation

/// Finds a spoken trigger phrase in streaming ASR text, tolerating small recognition errors
/// ("hey nimo" for "hey nemo"), and returns whatever was said after it.
public struct WakeWordDetector {
    public let words: [String]
    private var tail: [String] = []     // recent normalised words
    private let window = 12

    public init(phrase: String) {
        words = WakeWordDetector.normalise(phrase)
    }

    public static func normalise(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Feed newly recognised text. If the phrase completes inside the recent words, returns the text
    /// after it (possibly empty) and resets; otherwise nil.
    public mutating func feed(_ text: String) -> String? {
        let new = WakeWordDetector.normalise(text)
        guard !new.isEmpty, !words.isEmpty else { return nil }
        tail.append(contentsOf: new)
        if tail.count > window { tail.removeFirst(tail.count - window) }
        let n = words.count
        // only accept a match that ends within the words just added, so we do not re-trigger
        let firstNewEnd = tail.count - new.count + 1
        for end in stride(from: tail.count, through: firstNewEnd, by: -1) {
            // word by word ("hey nimo"), then the run-together spelling ("heynemo", "hey ne mo")
            if end >= n, matches(Array(tail[(end - n)..<end])) { return trigger(at: end) }
            for len in 1...min(n + 1, end) where len != n {
                if joinedMatches(Array(tail[(end - len)..<end])) { return trigger(at: end) }
            }
        }
        return nil
    }

    private mutating func trigger(at end: Int) -> String {
        let after = Array(tail[end...])
        tail.removeAll()
        return after.joined(separator: " ")
    }

    public mutating func reset() { tail.removeAll() }

    private func matches(_ candidate: [String]) -> Bool {
        for (a, b) in zip(candidate, words) {
            if WakeWordDetector.distance(a, b) > WakeWordDetector.allowed(for: b.count) { return false }
        }
        return true
    }

    private func joinedMatches(_ candidate: [String]) -> Bool {
        let phrase = words.joined()
        let spoken = candidate.joined()
        guard abs(spoken.count - phrase.count) <= 2 else { return false }
        return WakeWordDetector.distance(spoken, phrase) <= WakeWordDetector.allowed(for: phrase.count)
    }

    static func allowed(for length: Int) -> Int { length <= 3 ? 0 : (length <= 5 ? 1 : 2) }

    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}
