import Foundation

/// What the wearer asked this feature to do, once the wake word is stripped.
enum FoodLabelCommand: Equatable {
    enum ReadKind: Equatable {
        /// "read this label" — steps 1–4 of read mode.
        case headline
        /// "read the ingredients" — the full ingredients list.
        case ingredients
        /// "read the nutrition" — the per-serving numbers.
        case nutrition
        /// "read everything" — `fullText`.
        case everything
    }

    enum QuestionKind: Equatable {
        case sodium, sugar, carbs, fat
        /// "does this have peanuts" / "is there milk in this".
        case contains(String)
        case expiration
        case preparation
        /// The findings the check didn't have room for.
        case whatElse
    }

    case read(ReadKind)
    case check
    case question(QuestionKind)
}

/// Pure phrase matching for the handler chain (PRD-food-label § 10b). Commands
/// arrive lower-cased and punctuation-stripped by `WakeWordDetector.normalize`
/// ("what's in this" → "what s in this"), so matching is on normalized text.
///
/// The claimed lists are a contract: they must **not** include Feature 4's
/// "read this to me" / "read this", Feature 5's "check this ad", or anything
/// the calendar features own. Anything not listed here returns nil fast — no
/// network, a handful of string checks.
enum FoodLabelCommandParser {
    // Read mode — all route to one capture.
    static let headlinePhrases = [
        "read this label", "read the label", "read this package", "what's in this", "whats in this",
        "what is in this",
    ]
    static let ingredientsPhrases = ["read the ingredients", "read me the ingredients", "read ingredients"]
    static let nutritionPhrases = ["read the nutrition", "read the nutrition facts", "read nutrition"]
    static let everythingPhrases = ["read everything on this", "read everything", "read the whole label"]

    // Check mode.
    static let checkPhrases = [
        "can i eat this", "can i have this", "is this okay for me", "is this ok for me",
        "is this good for me", "check this food", "is this safe for me to eat", "does this fit my diet",
    ]

    // Question mode.
    static let sodiumPhrases = ["how much sodium", "how much salt"]
    static let sugarPhrases = ["how much sugar", "how much added sugar", "how many sugars"]
    static let carbsPhrases = ["how many carbs", "how many carbohydrates", "how much carbs", "how many carb"]
    static let fatPhrases = ["how much fat", "how much saturated fat"]
    static let expirationPhrases = ["when does this expire", "when does it expire", "what's the expiration", "whats the expiration"]
    static let preparationPhrases = ["how do i cook this", "how do i make this", "how do i prepare this", "how do i heat this"]
    static let whatElsePhrases = ["what else"]

    /// Every fixed phrase this feature claims, normalized — for tests that
    /// check the contract.
    static var claimedPhrases: [String] {
        (headlinePhrases + ingredientsPhrases + nutritionPhrases + everythingPhrases + checkPhrases
            + sodiumPhrases + sugarPhrases + carbsPhrases + fatPhrases + expirationPhrases
            + preparationPhrases + whatElsePhrases).map(normalize)
    }

    static func parse(_ command: String) -> FoodLabelCommand? {
        let text = normalize(command)
        guard !text.isEmpty else { return nil }

        // Fixed phrases: the command is the phrase or starts with it ("how much
        // sodium is in this"). Longer phrases first so "read the nutrition
        // facts" isn't half-matched.
        if matches(text, everythingPhrases) { return .read(.everything) }
        if matches(text, ingredientsPhrases) { return .read(.ingredients) }
        if matches(text, nutritionPhrases) { return .read(.nutrition) }
        if matches(text, headlinePhrases) { return .read(.headline) }
        if matches(text, checkPhrases) { return .check }
        if matches(text, sodiumPhrases) { return .question(.sodium) }
        if matches(text, sugarPhrases) { return .question(.sugar) }
        if matches(text, carbsPhrases) { return .question(.carbs) }
        if matches(text, fatPhrases) { return .question(.fat) }
        if matches(text, expirationPhrases) { return .question(.expiration) }
        if matches(text, preparationPhrases) { return .question(.preparation) }
        // Exact only: "what else do I have today" is the calendar's, not ours.
        if whatElsePhrases.contains(where: { normalize($0) == text }) { return .question(.whatElse) }

        // "does this have <x>" / "is there <x> in this" — the one open slot.
        if let word = containsQuery(text) { return .question(.contains(word)) }

        return nil
    }

    /// Lowercase, punctuation → spaces, collapsed — the same normalization the
    /// wake-word pipeline applies, so tests can pass either spelling.
    static func normalize(_ text: String) -> String {
        WakeWordDetector.normalize(text)
    }

    private static func matches(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { phrase in
            let p = normalize(phrase)
            return text == p || text.hasPrefix(p + " ")
        }
    }

    /// Extracts <x> from "does this have <x>" / "does this contain <x>" (with
    /// an optional "in it"), and from "is there <x> in this" — the "in this"
    /// is required there so "is there anything on my calendar" stays with the
    /// calendar features.
    static func containsQuery(_ text: String) -> String? {
        let suffixes = [" in this", " in it", " in here"]

        func strip(_ rest: String) -> String? {
            var word = rest
            for suffix in suffixes where word.hasSuffix(suffix) {
                word = String(word.dropLast(suffix.count))
            }
            if word.hasPrefix("any ") { word = String(word.dropFirst(4)) }
            word = word.trimmingCharacters(in: .whitespaces)
            // A bare "does this have" (nothing after) isn't ours to answer, and
            // a long tail isn't an ingredient name.
            guard !word.isEmpty, word.split(separator: " ").count <= 3 else { return nil }
            return word
        }

        for prefix in ["does this have ", "does this contain "] where text.hasPrefix(prefix) {
            return strip(String(text.dropFirst(prefix.count)))
        }
        if text.hasPrefix("is there "), suffixes.contains(where: text.hasSuffix) {
            return strip(String(text.dropFirst("is there ".count)))
        }
        return nil
    }
}
