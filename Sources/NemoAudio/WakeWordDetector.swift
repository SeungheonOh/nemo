import Foundation

/// Finds a spoken trigger phrase in streaming ASR text, tolerating small recognition errors
/// ("hey nimo" for "hey nemo"), and returns whatever was said after it.
///
/// The recogniser emits text in chunks and a word can be split across two of them ("Spar" + "k").
/// A chunk that starts without a space continues the previous word, so it is glued on rather than
/// treated as new dictation, and a fuzzy match whose last word is only a prefix of the wake word is
/// held back until the next chunk (or `flushPending` on a timeout) says whether the word went on.
public struct WakeWordDetector {
    public let words: [String]
    private var tail: [String] = []     // recent normalised words
    private let window = 12
    private var pending: Range<Int>?    // a held-back match, as indices into `tail`

    public init(phrase: String) {
        words = WakeWordDetector.normalise(phrase)
    }

    public static func normalise(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// True while a fuzzy match is waiting for the next chunk; call `flushPending` if none comes.
    public var hasPending: Bool { pending != nil }

    /// Feed newly recognised text. If the phrase completes inside the recent words, returns the text
    /// after it (possibly empty) and resets; otherwise nil.
    public mutating func feed(_ text: String) -> String? {
        var new = WakeWordDetector.normalise(text)
        guard !words.isEmpty else { return nil }
        // glued to the previous word (no space, no punctuation in front): a sub-word continuation
        let glued = text.first.map { $0.isLetter || $0.isNumber } ?? false
        var newCount = new.count

        if let held = pending {
            pending = nil
            if glued, let frag = new.first, !tail.isEmpty {
                // the held word went on: "spar" + "k" → does it still match?
                tail[held.upperBound - 1] += frag
                new.removeFirst()
                if matches(Array(tail[held])) || joinedMatches(Array(tail[held])) {
                    return trigger(after: new)
                }
                // it became another word ("sparrow"): drop the match, keep matching from here
                newCount = new.count + 1
            } else {
                // a new word or a pause followed: the fuzzy match stands
                return trigger(after: new)
            }
        } else if glued, let frag = new.first, !tail.isEmpty {
            tail[tail.count - 1] += frag
            new.removeFirst()
            newCount = new.count + 1   // the merged word counts as new too
        }

        tail.append(contentsOf: new)
        if tail.count > window { tail.removeFirst(tail.count - window) }
        guard newCount > 0, !tail.isEmpty else { return nil }
        let n = words.count
        // only accept a match that ends within the words just added, so we do not re-trigger
        let firstNewEnd = max(1, tail.count - newCount + 1)
        for end in stride(from: tail.count, through: firstNewEnd, by: -1) {
            var found: Range<Int>?
            // word by word ("hey nimo"), then the run-together spelling ("heynemo", "hey ne mo")
            if end >= n, matches(Array(tail[(end - n)..<end])) { found = (end - n)..<end }
            if found == nil {
                for len in 1...min(n + 1, end) where len != n {
                    if joinedMatches(Array(tail[(end - len)..<end])) { found = (end - len)..<end; break }
                }
            }
            guard let range = found else { continue }
            // the chunk ended on this word and it is only a prefix of the wake word ("spar" for
            // "spark"): the rest may be in the next chunk, so wait for it
            if end == tail.count, isStrictPrefix(Array(tail[range])) {
                pending = range
                return nil
            }
            return trigger(after: Array(tail[end...]))
        }
        return nil
    }

    /// No further text arrived after a held-back match: accept it.
    public mutating func flushPending() -> String? {
        guard pending != nil else { return nil }
        pending = nil
        return trigger(after: [])
    }

    public mutating func reset() { tail.removeAll(); pending = nil }

    private mutating func trigger(after: [String]) -> String {
        tail.removeAll()
        pending = nil
        return after.joined(separator: " ")
    }

    private func matches(_ candidate: [String]) -> Bool {
        guard candidate.count == words.count else { return false }
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

    /// The spoken words, run together, are a proper prefix of the wake phrase run together.
    private func isStrictPrefix(_ candidate: [String]) -> Bool {
        let spoken = candidate.joined(), phrase = words.joined()
        return spoken.count < phrase.count && phrase.hasPrefix(spoken)
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
