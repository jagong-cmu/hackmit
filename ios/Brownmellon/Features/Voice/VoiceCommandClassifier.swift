import Foundation

/// A command the phone can act on without asking the backend.
///
/// Everything that is a camera trigger, a phone call, or a yes/no has a small
/// closed vocabulary, so it is classified here — on-device, offline, and with
/// no model quota spent. Only commands with a date or time in them (features
/// 1–2) need the backend's language model, and the backend also recognizes
/// these same intents as a fallback for phrasings this list misses.
enum LocalVoiceCommand: Equatable {
    /// Feature 3 — "scan this".
    case scanCard
    /// Feature 4 — "read this to me".
    case readText
    /// Feature 5 — "check this ad".
    case checkAd
    /// Feature 6 — "call 911".
    case callEmergency
    /// Feature 6 — "call my daughter". Payload is what the wearer called the
    /// person, normalized ("daughter"), to match against configured contacts.
    case callContact(String)
    /// "Hey Dojo, yes" — answering a confirm-before-write question.
    case confirmYes
    case confirmNo
}

/// Turns the words after "Hey Dojo" into a `LocalVoiceCommand`, or nil when
/// the command needs the backend (scheduling, briefing, or anything unclear).
///
/// Matching is deliberately loose about the *object* and strict about the
/// *verb*: "scan this", "scan the card", "scan my appointment card" all mean
/// the same thing, but "check my calendar" must not become an ad check. Speech
/// recognition also mangles short words — "check this ad" reliably arrives as
/// "check this add" or "check this at" — so we never key on "ad" alone.
struct VoiceCommandClassifier {
    private static let callVerbs: Set<String> = ["call", "phone", "dial", "ring"]
    private static let readVerbs: Set<String> = ["read", "reed", "red"]
    private static let scanVerbs: Set<String> = ["scan", "scanned", "scanning", "skan"]
    private static let checkVerbs: Set<String> = ["check", "cheque", "checked"]

    /// Anything with these words is a calendar question, not a camera command,
    /// regardless of the verb ("read me my schedule", "check my calendar").
    private static let calendarWords: Set<String> = [
        "calendar", "schedule", "agenda", "appointments", "reminder", "reminders",
        "today", "tomorrow", "tonight", "week", "remind",
    ]

    /// Words that mean the wearer is asking whether something is a scam.
    private static let scamWords: Set<String> = [
        "scam", "scams", "scammer", "scammy", "legit", "legitimate", "fraud",
        "fraudulent", "fake", "suspicious", "phishing",
    ]

    /// Filler the wearer may wrap a contact name in: "call up my daughter now".
    private static let contactFiller: Set<String> = [
        "my", "the", "a", "an", "up", "to", "now", "please", "for", "me", "right",
    ]

    private static let confirmations = ConfirmationDetector()

    func classify(_ command: String) -> LocalVoiceCommand? {
        let tokens = WakeWordDetector.normalize(command).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }

        // Emergency first, and never behind anything else: a wrong branch here
        // costs the wearer time when they have the least of it.
        if Self.isEmergency(tokens) { return .callEmergency }

        if let name = Self.contactName(tokens) { return .callContact(name) }

        // "Is this a scam?" wins over the verb — "read this scam letter to me"
        // is still a scam question in the wearer's mind.
        if tokens.contains(where: Self.scamWords.contains) { return .checkAd }
        if Self.matchesPhrase(tokens, ["is", "this", "real"]) || Self.matchesPhrase(tokens, ["is", "that", "real"]) {
            return .checkAd
        }

        let mentionsCalendar = tokens.contains(where: Self.calendarWords.contains)

        if Self.readVerbs.contains(tokens[0]) || Self.asksWhatItSays(tokens) {
            return mentionsCalendar ? nil : .readText
        }

        // "card" anywhere means the physical appointment card, even when the
        // sentence also says "calendar" ("add this card to my calendar").
        if Self.scanVerbs.contains(tokens[0]) || tokens.contains("card") {
            return .scanCard
        }

        if Self.checkVerbs.contains(tokens[0]) {
            return mentionsCalendar ? nil : .checkAd
        }

        // A bare answer only — "no, wait, remind me at nine" is a scheduling
        // command that happens to start with "no", and belongs to the backend.
        if tokens.count <= 3, let answer = Self.confirmations.detect(in: tokens) {
            return answer ? .confirmYes : .confirmNo
        }

        return nil
    }

    // MARK: - Emergency

    private static func isEmergency(_ tokens: [String]) -> Bool {
        if tokens == ["emergency"] || tokens == ["this", "is", "an", "emergency"] || tokens == ["it", "s", "an", "emergency"] {
            return true
        }
        guard let verbIndex = tokens.firstIndex(where: callVerbs.contains) else { return false }
        let rest = Array(tokens[(verbIndex + 1)...]).filter { !contactFiller.contains($0) }
        guard let first = rest.first else { return false }

        if first == "911" || first == "emergency" || first == "police" || first == "ambulance" || first == "paramedics" {
            return true
        }
        // "nine one one", "nine eleven", "nine-one-one" (normalize splits on the dashes).
        if first == "nine" {
            let tail = Array(rest.dropFirst().prefix(2))
            return tail == ["one", "one"] || tail.first == "eleven"
        }
        return false
    }

    // MARK: - Contacts

    /// "call my daughter", "phone my son please" → "daughter" / "son".
    /// Only fires when the command *starts* with a call verb (allowing one
    /// leading filler word), so "remind me to call the dentist" stays a
    /// scheduling command.
    private static func contactName(_ tokens: [String]) -> String? {
        let verbIndex: Int
        if callVerbs.contains(tokens[0]) {
            verbIndex = 0
        } else if tokens.count > 1, contactFiller.contains(tokens[0]), callVerbs.contains(tokens[1]) {
            verbIndex = 1
        } else {
            return nil
        }
        let name = tokens[(verbIndex + 1)...].filter { !contactFiller.contains($0) }
        return name.isEmpty ? nil : name.joined(separator: " ")
    }

    // MARK: - Read

    /// "what does this say", "what does it say", "what's this say".
    private static func asksWhatItSays(_ tokens: [String]) -> Bool {
        guard tokens.first == "what", tokens.contains("say") || tokens.contains("says") else { return false }
        return tokens.contains("this") || tokens.contains("it") || tokens.contains("that")
    }

    private static func matchesPhrase(_ tokens: [String], _ phrase: [String]) -> Bool {
        guard tokens.count >= phrase.count else { return false }
        for start in 0...(tokens.count - phrase.count) where Array(tokens[start..<(start + phrase.count)]) == phrase {
            return true
        }
        return false
    }
}

/// Reads a short spoken answer to a yes/no question.
///
/// The assistant's own question leaks into the mic ("…should I add it to your
/// calendar?"), so this only looks at the first few words and never at
/// anything the assistant itself says: no "add", no "okay I will", nothing
/// that could turn our question into our answer. A negative anywhere in the
/// window wins over a positive ("no, that's not right").
struct ConfirmationDetector {
    private static let yesWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "ya", "yah", "sure", "okay", "ok", "correct",
        "right", "confirm", "confirmed", "affirmative", "absolutely", "definitely",
    ]
    private static let noWords: Set<String> = [
        "no", "nope", "nah", "never", "cancel", "don", "dont", "not", "wrong",
        "stop", "skip", "incorrect", "negative",
    ]
    /// How many leading words we read. Long enough for "um, yes please",
    /// short enough that a sentence starting elsewhere can't sneak a yes in.
    private static let window = 3

    /// `true` for yes, `false` for no, nil when the words aren't an answer.
    func detect(in tokens: [String]) -> Bool? {
        let head = tokens.prefix(Self.window)
        if head.contains(where: Self.noWords.contains) { return false }
        if head.contains(where: Self.yesWords.contains) { return true }
        return nil
    }

    func detect(in transcript: String) -> Bool? {
        detect(in: WakeWordDetector.normalize(transcript).split(separator: " ").map(String.init))
    }
}
