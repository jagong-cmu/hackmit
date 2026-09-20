import Foundation

/// What the wearer asked the memory feature to do, classified from a
/// normalized command (see `WakeWordDetector.normalize`).
enum MemoryCommand: Equatable {
    /// `text` is the note with the "remember …" prefix stripped. Empty with
    /// `wantsParkingPhoto` means "remember where I parked" — photograph the
    /// spot marker; empty without it is a rejection ("Remember what?").
    case save(text: String, wantsParkingPhoto: Bool, isParking: Bool)
    case recallParking
    case directionsToCar
    case recall(question: String)
    case forgetLastParking
    case forgetLast
    case forgetAllRequest
    case forgetAllConfirm
    /// "forget …" phrased in a way none of the rules recognize. Still claimed
    /// (the contract is "starts with forget") but never destructive — the
    /// handler asks which of the three it should do.
    case forgetUnrecognized
    /// "forget it" / "never mind" — the everyday way to cancel, not a request
    /// to delete anything. Claimed so the wearer hears a calm "Okay." instead
    /// of the calendar parser's "Sorry, I didn't catch that."
    case dismiss
}

/// Pure string classification for the memory feature (PRD-memory § Command
/// routing). Rules run in this order: forget → save → parking recall →
/// directions → general recall → nil. Matching is literal on whole words —
/// no fuzzy matching of ordinary English (that's only for the wake word).
///
/// Every phrase list below is a contract with the other voice features: this
/// parser claims exactly these and nothing else. In particular it never
/// claims `remind …` (Feature 1) or anything mentioning the calendar.
enum MemoryCommandParser {
    /// Normalization turns "don't" into "don t", so the apostrophe variants
    /// are spelled out. Longest first so "remember that" wins over "remember".
    static let savePrefixes = [
        "remember that",
        "remember",
        "note that",
        "don t forget that",
        "don't forget that",
        "dont forget that",
        "make a note that",
    ]

    /// A save whose whole remainder is one of these means "photograph the
    /// spot marker" rather than "note these words".
    static let parkingPhotoPhrases: Set<String> = [
        "where i parked",
        "where i m parked",
        "where im parked",
        "where i am parked",
        "where i parked my car",
        "where i parked the car",
        "where my car is parked",
        "where the car is parked",
        "where i left my car",
        "where i left the car",
        "my parking spot",
        "my parking space",
        "where my car is",
        "where the car is",
    ]

    /// A courtesy word many wearers put before or after a command ("please
    /// remember …", "forget that please"). Stripped before the prefix rules so
    /// politeness never sends a note to the calendar parser. Only this one
    /// word: "can you remember where I parked" is a *question* and must keep
    /// reaching the recall rules, so lead-ins like "can you" are left alone.
    static let courtesyWord = "please"

    static let parkingRecallPhrases = [
        "where did i park",
        "where s my car",
        "wheres my car",
        "where is my car",
        "where did i leave the car",
        "where did i leave my car",
        "where am i parked",
        "where is the car",
        "where s the car",
        "wheres the car",
        "where i parked",
        "where my car is",
    ]

    static let directionsPhrases = [
        "take me to my car",
        "take me to the car",
        "directions to my car",
        "directions to the car",
        "navigate to my car",
        "walk me to my car",
        "get me to my car",
        "guide me to my car",
    ]

    static let generalRecallPhrases = [
        "where did i put",
        "where s my",
        "wheres my",
        "where is my",
        "where are my",
        "where did i leave",
        "what did i tell you",
        "what did i say about",
        "do you remember",
        "what do you remember about",
        "what did i ask you to remember",
    ]

    /// Anything with one of these is calendar territory (Features 1–2), even
    /// if it also says "where is my …".
    static let calendarWords: Set<String> = ["appointment", "appointments", "meeting", "meetings", "schedule", "calendar"]

    static let forgetAllPhrases: Set<String> = [
        "everything",
        "all",
        "all my notes",
        "all of my notes",
        "everything you know",
        "all of it",
    ]

    /// Never "it": "forget it" means "never mind" (see `dismissPhrases`), and
    /// deleting a note on the universal cancel word is a trap.
    static let forgetLastPhrases: Set<String> = [
        "that",
        "the last thing",
        "the last one",
        "the last note",
        "that last thing",
        "the last thing i said",
        "the last thing i told you",
        "what i just said",
        "what i just told you",
    ]

    static let forgetAllConfirmation = "yes forget everything"

    /// Whole commands that mean "never mind". Non-destructive. Deliberately
    /// not "cancel": after "remind me to take my pills at 8", a "cancel that"
    /// answered with "Okay." would falsely confirm a calendar change this
    /// feature can't make — it must keep reaching the calendar parser.
    static let dismissPhrases: Set<String> = [
        "forget it",
        "forget about it",
        "never mind",
        "nevermind",
        "never mind that",
    ]

    /// "where's my car …" followed by one of these is about the car's
    /// belongings, not where it is parked — general recall, not parking.
    static let carAccessoryWords: Set<String> = [
        "key", "keys", "seat", "seats", "charger", "door", "title", "insurance", "registration",
        "payment", "wash", "manual", "remote", "fob",
    ]

    static func parse(_ rawCommand: String) -> MemoryCommand? {
        // The voice path already normalized; the typed Simulator field did
        // not. Normalizing is idempotent, so do it unconditionally.
        let command = strippingCourtesy(WakeWordDetector.normalize(rawCommand))
        guard !command.isEmpty else { return nil }

        // Feature 1's word. Even "remind me where I parked" is a reminder,
        // not a recall — the PRD forbids claiming anything starting with it.
        if remainder(of: command, afterPrefix: "remind") != nil { return nil }

        if dismissPhrases.contains(command) { return .dismiss }
        if let forget = parseForget(command) { return forget }
        if let save = parseSave(command) { return save }

        if mentionsCalendar(command) { return nil }
        if containsAny(command, parkingRecallPhrases), !mentionsCarAccessory(command) { return .recallParking }
        if containsAny(command, directionsPhrases) { return .directionsToCar }
        if containsAny(command, generalRecallPhrases) { return .recall(question: command) }
        return nil
    }

    // MARK: - Rules

    static func parseForget(_ command: String) -> MemoryCommand? {
        if command == forgetAllConfirmation { return .forgetAllConfirm }
        guard let rest = remainder(of: command, afterPrefix: "forget") else { return nil }

        if forgetAllPhrases.contains(rest) { return .forgetAllRequest }
        if mentionsParking(rest) || words(rest).contains("car") { return .forgetLastParking }
        if forgetLastPhrases.contains(rest) { return .forgetLast }
        return .forgetUnrecognized
    }

    static func parseSave(_ command: String) -> MemoryCommand? {
        for prefix in savePrefixes {
            guard let text = remainder(of: command, afterPrefix: prefix) else { continue }
            if text.isEmpty {
                return .save(text: "", wantsParkingPhoto: false, isParking: false)
            }
            if parkingPhotoPhrases.contains(text) {
                return .save(text: "", wantsParkingPhoto: true, isParking: true)
            }
            return .save(text: text, wantsParkingPhoto: false, isParking: mentionsParking(text))
        }
        return nil
    }

    // MARK: - Word-level helpers

    /// Drops one leading and/or one trailing "please" (whole words) from an
    /// already-normalized command. A bare "please" becomes "".
    static func strippingCourtesy(_ command: String) -> String {
        var tokens = words(command)
        if tokens.first == courtesyWord { tokens.removeFirst() }
        if tokens.last == courtesyWord { tokens.removeLast() }
        return tokens.joined(separator: " ")
    }

    /// "park", "parked", "parking", … as a whole word.
    static func mentionsParking(_ text: String) -> Bool {
        words(text).contains { $0.hasPrefix("park") }
    }

    static func mentionsCalendar(_ text: String) -> Bool {
        words(text).contains { calendarWords.contains($0) }
    }

    /// "where's my car keys" is a question about keys.
    static func mentionsCarAccessory(_ text: String) -> Bool {
        words(text).contains { carAccessoryWords.contains($0) }
    }

    /// Whole-word containment: `phrase` must start and end on word
    /// boundaries, so "where is my car" does not fire on "where is my cart".
    static func containsAny(_ command: String, _ phrases: [String]) -> Bool {
        let padded = " \(command) "
        return phrases.contains { padded.contains(" \($0) ") }
    }

    /// The text after `prefix` when the command starts with it as whole
    /// words; empty when the command *is* the prefix; nil when it doesn't
    /// start with it.
    static func remainder(of command: String, afterPrefix prefix: String) -> String? {
        if command == prefix { return "" }
        guard command.hasPrefix(prefix + " ") else { return nil }
        return String(command.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func words(_ text: String) -> [String] {
        text.split(separator: " ").map(String.init)
    }
}
