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

    /// `command` arrives lower-cased and punctuation-stripped
    /// (`WakeWordDetector.normalize`).
    static func claims(_ command: String) -> Bool {
        claimedPhrases.contains { command.contains($0) }
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
