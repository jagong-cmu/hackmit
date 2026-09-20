import Foundation

/// The product copy the memory feature speaks (PRD-memory § 9a–9c) and the
/// small amount of text repair needed to read a normalized note back so it
/// sounds like the wearer said it: "i parked in section b" → "I parked in
/// section B".
enum MemorySpeech {
    // MARK: - Save (9a)

    static let rememberWhat = "Remember what? Try: Hey Dojo, remember I parked in section B."
    static func rememberedNote(_ text: String) -> String {
        "Got it. I'll remember: \(spokenNoteText(text))."
    }
    static func savedParkingWithSign(_ signText: String) -> String {
        "Got it. I saved your parking spot — the sign says \(signText)."
    }
    static let savedParking = "Got it. I saved where you're parked."
    static let savedParkingWithoutPermission =
        "Got it. I saved a note that you parked, but I can't save the location without permission. You can turn it on in Settings."
    static let couldNotSave = "Sorry, I couldn't save that. Please try again."

    // MARK: - Recall (9b)

    static let noParkingSaved = "I don't have a parking spot saved. Next time, say: Hey Dojo, remember where I parked."
    static let openingDirections = "Opening walking directions on your phone."
    static let noCarLocation = "I don't have your car's location saved."
    static let nothingRemembered = "You haven't asked me to remember anything yet."
    static let recallUnavailable = "I couldn't check my notes just now. Please try again."

    // MARK: - Forget (9c)

    static let confirmForgetAll = "Say 'Hey Dojo, yes, forget everything' to confirm."
    static let nothingToForget = "I don't have any notes to forget."
    static let noParkingToForget = "I don't have a parking spot saved."
    static let nothingToConfirm = "Nothing to confirm. To clear your notes, say: Hey Dojo, forget everything."
    static let forgetHelp = "I can forget your parking spot, the last thing you told me, or everything. Which would you like?"
    static let couldNotForget = "Sorry, I couldn't forget that. Please try again."

    static func forgotEverything(count: Int) -> String {
        count == 1 ? "Okay. I forgot your one note." : "Okay. I forgot all \(count) of your notes."
    }

    /// Every deletion is confirmed with the note's content.
    static func forgot(_ note: MemoryNote) -> String {
        let text = note.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            return "Okay. I forgot: \(spokenNoteText(text))."
        }
        if let sign = note.signText, note.hasSignText {
            return "Okay. I forgot your parking spot — the sign said \(sign)."
        }
        return "Okay. I forgot your parking spot."
    }

    // MARK: - Reading a normalized note back

    private static let placeWords: Set<String> = [
        "section", "sections", "level", "row", "lot", "aisle", "zone", "spot", "space", "floor",
        "gate", "door", "area", "block", "column", "terminal", "garage", "deck", "building", "bay", "pier",
    ]

    /// Tokens that normalization split off a contraction, keyed by the
    /// words they may follow. "i m" → "I'm", "don t" → "don't".
    private static let contractionTails: [String: Set<String>] = [
        "m": ["i"],
        "ll": ["i", "you", "we", "they", "it", "he", "she", "that"],
        "ve": ["i", "you", "we", "they"],
        "re": ["you", "we", "they"],
        "d": ["i", "you", "we", "they", "he", "she"],
        "s": ["it", "that", "there", "here", "he", "she", "what", "where", "who", "let", "everything", "something", "nothing"],
        "t": [
            "don", "didn", "doesn", "can", "won", "isn", "wasn", "aren", "weren", "haven", "hasn", "hadn",
            "couldn", "wouldn", "shouldn", "mustn", "needn", "ain",
        ],
    ]

    /// Repairs what `WakeWordDetector.normalize` did to the wearer's words so
    /// TTS reads them naturally: standalone "i" → "I", single letters that
    /// name a place ("section b") → uppercase, contractions re-joined, first
    /// letter capitalized. Everything else stays exactly as recognized.
    static func spokenNoteText(_ normalized: String) -> String {
        let tokens = normalized.split(separator: " ").map(String.init)
        var output: [String] = []

        for token in tokens {
            let previous = output.last?.lowercased()

            if let previous, let tails = contractionTails[token], tails.contains(previous) {
                output[output.count - 1] += "'" + token
                continue
            }
            if token == "i" {
                output.append("I")
                continue
            }
            if token.count == 1, let letter = token.first, letter.isLetter {
                if token != "a" || (previous.map { placeWords.contains($0) } ?? false) {
                    output.append(token.uppercased())
                    continue
                }
            }
            output.append(token)
        }

        let sentence = output.joined(separator: " ")
        guard let first = sentence.first else { return sentence }
        return first.uppercased() + sentence.dropFirst()
    }
}
