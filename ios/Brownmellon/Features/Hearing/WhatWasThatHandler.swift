import Foundation

/// "Hey Dojo, what was that?" (PRD-sound-alerts § 8b). The phrase contract
/// and the spoken replies live here as pure functions; `SoundAlertMonitor`
/// is the `VoiceCommandHandler` that calls them (see its extension below).
enum WhatWasThatResponder {
    /// Commands *containing* any of these are ours. Anything else falls
    /// through to the next handler — a couple of string checks, nothing more.
    static let claimedPhrases: [String] = [
        "what was that",
        "what was that sound",
        "what was that noise",
        "did you hear that",
        "what did you hear",
    ]

    static let disabledReply = "Sound alerts are turned off. Your helper can turn them on in Setup."
    static let nothingReply = "I didn't notice anything unusual in the last minute."

    /// Words that may follow a claimed phrase and still mean "that sound":
    /// "what was that noise just now", "did you hear that beeping".
    static let soundTailWords: Set<String> = [
        "sound", "sounds", "noise", "noises", "beep", "beeping", "beeps", "ringing", "ring", "bang",
        "banging", "alarm", "buzzing", "buzz", "just", "now", "a", "minute", "second", "ago", "earlier",
        "outside", "there", "again", "please",
    ]

    /// Never ours: "what was that appointment again" is a calendar question.
    static let calendarWords: Set<String> = ["appointment", "appointments", "meeting", "meetings", "schedule", "calendar"]

    /// `command` is normalized (lower-cased, punctuation stripped) here too,
    /// so the typed Simulator field behaves like the wake-word path. Claims a
    /// command only when it is one of the phrases, optionally followed by
    /// sound words — "what was that address I told you" is somebody else's.
    /// Hesitations people put in front of a question ("um, what was that?").
    static let leadInWords: Set<String> = ["um", "uh", "so", "hey", "okay", "ok", "well", "hmm", "oh", "wait", "please"]

    static func claims(_ rawCommand: String) -> Bool {
        var words = WakeWordDetector.normalize(rawCommand).split(separator: " ").map(String.init)
        if words.contains(where: { calendarWords.contains($0) }) { return false }
        while let first = words.first, leadInWords.contains(first) { words.removeFirst() }
        let command = words.joined(separator: " ")

        for phrase in claimedPhrases {
            guard command == phrase || command.hasPrefix(phrase + " ") else { continue }
            let tail = command.dropFirst(phrase.count).split(separator: " ").map(String.init)
            if tail.allSatisfy({ soundTailWords.contains($0) }) { return true }
        }
        return false
    }

    static func reply(isEnabled: Bool, observation: RecentSoundObservation?, now: Date) -> String {
        guard isEnabled else { return disabledReply }
        guard let observation, let entry = SoundCatalog.entry(for: observation.identifier) else {
            return nothingReply
        }
        let elapsed = now.timeIntervalSince(observation.timestamp)
        return "\(spokenElapsed(elapsed)) it sounded like \(entry.description)."
    }

    /// "Just now", "About ten seconds ago", … "About a minute ago". Spoken, so
    /// numbers are words and everything is rounded to the nearest five seconds.
    static func spokenElapsed(_ seconds: TimeInterval) -> String {
        let rounded = Int((max(0, seconds) / 5).rounded()) * 5
        if rounded < 5 { return "Just now" }
        if rounded >= 60 { return "About a minute ago" }
        return "About \(numberWords[rounded] ?? String(rounded)) seconds ago"
    }

    private static let numberWords: [Int: String] = [
        5: "five", 10: "ten", 15: "fifteen", 20: "twenty", 25: "twenty-five",
        30: "thirty", 35: "thirty-five", 40: "forty", 45: "forty-five",
        50: "fifty", 55: "fifty-five",
    ]
}

extension SoundAlertMonitor: VoiceCommandHandler {
    /// Claims only the § 8b phrases; returns false fast for everything else.
    func handle(_ command: String) async -> Bool {
        guard WhatWasThatResponder.claims(command) else { return false }
        let now = self.now()
        let reply = WhatWasThatResponder.reply(
            isEnabled: settings.isEnabled,
            observation: recentLog.mostNotable(now: now),
            now: now
        )
        await glasses.speak(reply)
        return true
    }
}
