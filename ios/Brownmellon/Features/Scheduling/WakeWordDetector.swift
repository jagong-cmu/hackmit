import Foundation

/// Spots "Hey Dojo" in a transcript and hands back whatever followed it.
///
/// Exact string matching does not survive contact with a real recognizer.
/// "Dojo" is a proper noun with no language-model prior, so ASR returns it as
/// "dodo", "doe joe", "dough joe" and friends — especially from an older
/// speaker, which is our entire user base. We therefore match a normalized
/// token against a list of known confusions plus a bounded edit distance.
///
/// The tradeoff runs the other way too: a short wake word accepted loosely
/// will fire on conversation that merely rhymes with it. `maxDistance` is the
/// dial — raise it if the wearer has to repeat themselves, lower it if the
/// assistant interrupts unprompted. Measure both before tuning.
struct WakeWordDetector {
    /// Canonical spelling — the one thing everyone says out loud in the demo.
    static let phrase = "Hey Dojo"

    /// Single-token spellings we accept for "dojo".
    private static let acceptedTokens: Set<String> = [
        "dojo", "dojos", "dodo", "dogo", "doji", "doughjoe",
    ]

    /// Spellings the recognizer splits across two tokens.
    private static let acceptedPairs: Set<String> = [
        "doe joe", "dough joe", "do jo", "doh joe", "dou jo",
    ]

    /// Openers we accept in place of "hey".
    private static let greetings: Set<String> = ["hey", "hay", "ay"]

    /// Edit distance tolerated against "dojo" for anything not listed above.
    private static let maxDistance = 1

    struct Match: Equatable {
        /// Everything said after the wake word, trimmed. Empty if the wearer
        /// said only the wake word and nothing else.
        let command: String
    }

    func detect(in transcript: String) -> Match? {
        detect(tokens: Self.tokenize(transcript))
    }

    /// First occurrence of the wake word. Right for a one-shot transcript.
    func detect(tokens: [String]) -> Match? {
        guard tokens.count >= 2 else { return nil }
        for index in tokens.indices {
            if let match = Self.match(tokens, greetingAt: index) { return match }
        }
        return nil
    }

    /// *Last* occurrence of the wake word. A streaming recognizer keeps the whole
    /// segment in one growing transcript — "hey dojo scan this … hey dojo read
    /// this" — and the command that matters is the one the wearer just said.
    func detectLatest(tokens: [String]) -> Match? {
        guard tokens.count >= 2 else { return nil }
        for index in tokens.indices.reversed() {
            if let match = Self.match(tokens, greetingAt: index) { return match }
        }
        return nil
    }

    private static func match(_ tokens: [String], greetingAt index: Int) -> Match? {
        guard greetings.contains(tokens[index]) else { return nil }
        let rest = Array(tokens.dropFirst(index + 1))
        guard let next = rest.first else { return nil }

        if matchesName(next) {
            return Match(command: rest.dropFirst().joined(separator: " "))
        }
        if rest.count >= 2, acceptedPairs.contains("\(next) \(rest[1])") {
            return Match(command: rest.dropFirst(2).joined(separator: " "))
        }
        return nil
    }

    static func tokenize(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }

    private static func matchesName(_ token: String) -> Bool {
        acceptedTokens.contains(token) || editDistance(token, "dojo") <= maxDistance
    }

    /// Lowercase, strip punctuation, collapse whitespace.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

/// Wraps `WakeWordDetector` with the debouncing a streaming recognizer needs.
///
/// `GlassesSession.startListening` emits a *growing* partial transcript — the
/// same utterance arrives over and over as the recognizer refines it. Firing on
/// each one would schedule the same appointment several times. This holds the
/// last command and a cooldown so one spoken sentence produces one action.
///
/// Workstreams B and C should drive their own triggers through this rather than
/// calling the detector directly.
final class WakeWordListener {
    private let detector = WakeWordDetector()
    private let cooldown: TimeInterval
    private var lastFiredAt: Date?
    private var lastCommand: String?

    init(cooldown: TimeInterval = 2.0) {
        self.cooldown = cooldown
    }

    /// Returns the command exactly once per utterance, or nil.
    func consume(_ transcript: String, now: Date = Date()) -> String? {
        guard let match = detector.detect(in: transcript) else { return nil }
        guard !match.command.isEmpty else { return nil }

        if let lastFiredAt, now.timeIntervalSince(lastFiredAt) < cooldown {
            // Same utterance still arriving — take the longer refinement but
            // don't act twice.
            if let lastCommand, match.command.hasPrefix(lastCommand) {
                self.lastCommand = match.command
            }
            return nil
        }

        lastFiredAt = now
        lastCommand = match.command
        return match.command
    }

    /// Call after the assistant finishes speaking, so its own audio bleeding
    /// into the mic doesn't count against the cooldown.
    func reset() {
        lastFiredAt = nil
        lastCommand = nil
    }
}
