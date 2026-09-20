import Foundation

/// Everything the wearer hears from this feature, as one place to review the
/// product copy (PRD-food-label § 10c / 10d). Read mode speaks a label in
/// listening order — headline facts first, detail on request — and check mode
/// speaks the fit verdict with the one or two reasons that matter.
///
/// Vocabulary rules: fractions in words ("about a third of your daily limit"),
/// never percentages; always per serving; the verdict is *fits / moderate fit /
/// doesn't fit your diet* — never "safe", "healthy", "you should" or "don't
/// eat". This compares label numbers to limits a person entered; it is not
/// medical advice.
enum FoodLabelSpeech {
    /// Prefix when a follow-up was answered from the cached label, so the
    /// wearer knows no new photo was taken.
    static let cachePrefix = "From the label I just read: "

    static let offer = "Say 'read the ingredients' for the full list, or 'read everything' for the whole label."

    // MARK: - Numbers in words

    enum Unit {
        case milligrams, grams, calories
    }

    /// "890 milligrams of sodium", "1 gram of sugar", "60 calories". Rounds to
    /// whole numbers; a positive amount that rounds to zero is "less than 1".
    static func quantity(_ value: Double, _ unit: Unit, of nutrient: String? = nil) -> String {
        let rounded = Int(value.rounded())
        let lessThanOne = value > 0 && rounded == 0
        let count = lessThanOne ? 1 : rounded
        let unitWord: String
        switch unit {
        case .milligrams: unitWord = count == 1 ? "milligram" : "milligrams"
        case .grams: unitWord = count == 1 ? "gram" : "grams"
        case .calories: unitWord = count == 1 ? "calorie" : "calories"
        }
        let number = lessThanOne ? "less than 1" : String(count)
        if unit == .calories || nutrient == nil {
            return "\(number) \(unitWord)"
        }
        return "\(number) \(unitWord) of \(nutrient ?? "")"
    }

    /// A share of the wearer's own limit, in words: "more than half of your
    /// daily limit", "about an eighth of your daily limit", "about half your
    /// meal budget". Never a percentage.
    static func fraction(_ ratio: Double, of noun: String) -> String {
        // Bands are the midpoints between neighbouring everyday fractions
        // (a tenth, an eighth, a fifth, a quarter, a third, half, three
        // quarters, the whole), so each ratio gets the nearest one.
        let word: String
        switch ratio {
        case ..<0.05: return "a small part of \(noun)"
        case ..<0.1125: word = "about a tenth"
        case ..<0.1625: word = "about an eighth"
        case ..<0.225: word = "about a fifth"
        case ..<0.29: word = "about a quarter"
        case ..<0.42: word = "about a third"
        case ..<0.55: word = "about half"
        case ..<0.70: word = "more than half"
        case ..<0.90: word = "about three quarters"
        case ...1.05: return "about \(possessiveWhole(noun))"
        default: return "more than \(possessiveWhole(noun))"
        }
        // "about half your meal budget" reads better than "about half of your
        // meal budget"; the daily-limit phrasing keeps the "of".
        let connector = word.hasSuffix("half") && noun == "your meal budget" ? " " : " of "
        return "\(word)\(connector)\(noun)"
    }

    /// "your daily limit" → "your whole daily limit".
    private static func possessiveWhole(_ noun: String) -> String {
        noun.hasPrefix("your ") ? "your whole " + noun.dropFirst("your ".count) : "the whole \(noun)"
    }

    /// Small counts in words; anything larger stays as digits (TTS reads
    /// digits fine — words matter for the numbers people say out loud).
    static func spokenNumber(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                     "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                     "eighteen", "nineteen", "twenty"]
        return (0...20).contains(n) ? words[n] : String(n)
    }

    /// Servings per container to the nearest half, in words: 2.5 → "two and a
    /// half", 2.3 → "two and a half", 4 → "four".
    static func spokenServings(_ servings: Double) -> String {
        let halves = (servings * 2).rounded()
        let whole = Int(halves / 2)
        let hasHalf = halves.truncatingRemainder(dividingBy: 2) != 0
        if whole == 0 { return hasHalf ? "half a" : "zero" }
        return hasHalf ? "\(spokenNumber(whole)) and a half" : spokenNumber(whole)
    }

    /// Mentioned whenever the container holds 1.5 servings or more — older
    /// adults often eat the whole thing, and this is the honest note without
    /// doing math the wearer didn't ask for.
    static func servingsSentence(_ servings: Double?) -> String? {
        guard let servings, servings >= 1.5 else { return nil }
        return "And the package is about \(spokenServings(servings)) servings."
    }

    /// "1 cup (245g)" → "1 cup"; "2/3 cup (55g)" → "two thirds cup"; "1 1/2
    /// cups (39g)" → "1 and a half cups". Drops the gram weight in parentheses
    /// — one unit is enough to listen to.
    static func spokenServingSize(_ printed: String) -> String {
        var text = printed
        if let regex = try? NSRegularExpression(pattern: "\\s*\\([^)]*\\)") {
            text = regex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        let fractions: [(digits: String, words: String, mixed: String)] = [
            ("1/2", "one half", "a half"), ("1/3", "one third", "a third"), ("2/3", "two thirds", "two thirds"),
            ("1/4", "one quarter", "a quarter"), ("3/4", "three quarters", "three quarters"),
            ("1/8", "one eighth", "an eighth"),
        ]
        for fraction in fractions {
            // A mixed number first ("1 1/2" → "1 and a half"), then a bare one.
            if let regex = try? NSRegularExpression(pattern: "(\\d+)\\s+\(NSRegularExpression.escapedPattern(for: fraction.digits))") {
                text = regex.stringByReplacingMatches(
                    in: text, options: [], range: NSRange(text.startIndex..., in: text),
                    withTemplate: "$1 and \(fraction.mixed)"
                )
            }
            text = text.replacingOccurrences(of: fraction.digits, with: fraction.words)
        }
        text = text.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? printed.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }

    /// Cleans one ingredient for speech: trims, drops a trailing period, and
    /// lowercases ALL-CAPS label text so TTS doesn't spell it out.
    static func spokenIngredient(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        if text == text.uppercased(), text.contains(where: \.isLetter) {
            text = text.lowercased()
        }
        return text
    }

    /// "a", "a and b", "a, b, and c".
    static func joinedList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }

    // MARK: - Read mode (§ 10c)

    /// Steps 1–4: product and servings, headline nutrients, what it contains,
    /// and the offer. Never `fullText` first.
    static func readHeadline(_ label: FoodLabelResult) -> String {
        var sentences: [String] = []
        sentences.append(productAndServingsSentence(label))
        sentences.append(nutrientsSentence(label))
        if let contains = containsSentence(label) { sentences.append(contains) }
        sentences.append(offer)
        return sentences.joined(separator: " ")
    }

    /// Step 1: "This is Campbell's Chicken Noodle Soup. One serving is one cup,
    /// and the package has about two and a half servings."
    static func productAndServingsSentence(_ label: FoodLabelResult) -> String {
        var parts: [String] = []
        if let name = label.productName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            parts.append("This is \(name).")
        } else {
            parts.append("I couldn't read the product name.")
        }

        let servingSize = label.servingSize.map(spokenServingSize).flatMap { $0.isEmpty ? nil : $0 }
        let servings = label.servingsPerContainer.flatMap { $0 >= 1.5 ? spokenServings($0) : nil }
        switch (servingSize, servings) {
        case let (size?, count?):
            parts.append("One serving is \(size), and the package has about \(count) servings.")
        case let (size?, nil):
            parts.append("One serving is \(size).")
        case let (nil, count?):
            parts.append("The package has about \(count) servings.")
        case (nil, nil):
            break
        }
        return parts.joined(separator: " ")
    }

    /// Step 2: "Per serving: 60 calories, 890 milligrams of sodium, 8 grams of
    /// carbohydrates with 1 gram of sugar, 2 grams of fat, 3 grams of protein."
    /// Only the fields that were read; units in words.
    static func nutrientsSentence(_ label: FoodLabelResult) -> String {
        let n = label.nutrients
        var parts: [String] = []
        if let calories = n.calories { parts.append(quantity(calories, .calories)) }
        if let sodium = n.sodiumMg { parts.append(quantity(sodium, .milligrams, of: "sodium")) }
        if let carbs = n.totalCarbohydrateG {
            var carbPart = quantity(carbs, .grams, of: "carbohydrates")
            if let sugar = n.totalSugarsG {
                carbPart += " with \(quantity(sugar, .grams, of: "sugar"))"
            } else if let added = n.addedSugarsG {
                carbPart += " with \(quantity(added, .grams, of: "added sugar"))"
            }
            parts.append(carbPart)
        } else if let sugar = n.totalSugarsG {
            parts.append(quantity(sugar, .grams, of: "sugar"))
        }
        if let fat = n.totalFatG { parts.append(quantity(fat, .grams, of: "fat")) }
        if let protein = n.proteinG { parts.append(quantity(protein, .grams, of: "protein")) }

        guard !parts.isEmpty else {
            return "I couldn't read the Nutrition Facts numbers on this label."
        }
        return "Per serving: \(parts.joined(separator: ", "))."
    }

    /// Step 3: "It contains wheat, chicken, and soy." — from the "Contains:"
    /// statement, else the first five ingredients.
    static func containsSentence(_ label: FoodLabelResult) -> String? {
        if let statement = IngredientMatcher.stripContainsLeadIn(label.containsStatement) {
            let items = splitList(statement).map(spokenIngredient)
            if !items.isEmpty { return "It contains \(joinedList(items))." }
        }
        let ingredients = IngredientMatcher.splitAdvisories(label.ingredients).ingredients
        guard !ingredients.isEmpty else { return nil }
        var items = Array(ingredients.prefix(5)).map(spokenIngredient)
        if ingredients.count > 5 { items.append("more") }
        return "It contains \(joinedList(items))."
    }

    /// "wheat, milk and soy" → ["wheat", "milk", "soy"].
    static func splitList(_ text: String) -> [String] {
        text.replacingOccurrences(of: " and ", with: ",")
            .replacingOccurrences(of: ";", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// "read the ingredients" — the full list, in at most two chunks with
    /// "… and" between them so a long list has a breath in it.
    static func ingredientsScript(_ label: FoodLabelResult) -> String {
        let items = label.ingredients.map(spokenIngredient).filter { !$0.isEmpty }
        guard !items.isEmpty else {
            return "I couldn't read the ingredients list on this label. Try a closer photo of the ingredients."
        }
        if items.count <= 8 {
            return "The ingredients are \(joinedList(items))."
        }
        let midpoint = (items.count + 1) / 2
        let first = items[..<midpoint].joined(separator: ", ")
        let second = items[midpoint...].joined(separator: ", ")
        return "The ingredients are \(first), … and \(second)."
    }

    /// "read everything" — the whole label as printed.
    static func everythingScript(_ label: FoodLabelResult) -> String {
        let text = label.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "I couldn't read the text on this label." : text
    }

    static func expirationScript(_ label: FoodLabelResult) -> String {
        if let date = label.expiration?.trimmingCharacters(in: .whitespacesAndNewlines), !date.isEmpty {
            return "The label says: \(date)."
        }
        return "I couldn't find a date on this side of the package."
    }

    static func preparationScript(_ label: FoodLabelResult) -> String {
        if let steps = label.preparation?.trimmingCharacters(in: .whitespacesAndNewlines), !steps.isEmpty {
            return "The label says: \(steps)"
        }
        return "I couldn't find cooking instructions on this side of the package."
    }

    // MARK: - Check mode (§ 10d)

    static let notALabelScript =
        "I don't see a nutrition label. Hold the Nutrition Facts panel or the ingredients list in front of you, about a foot from your face."

    static let noProfileLeadIn =
        "No diet has been set up yet, so I can't check this for you — your helper can add one in Setup. Here's the label:"

    /// Product → the top one or two findings → verdict → serving note.
    static func checkScript(_ assessment: FitAssessment, label: FoodLabelResult, profile: DietaryProfile) -> String {
        switch assessment.verdict {
        case .notALabel:
            return notALabelScript

        case .noProfile:
            return "\(noProfileLeadIn) \(nutrientsSentence(label))"

        case .unknown:
            return unknownScript(assessment)

        case .doesNotFit:
            var sentences: [String] = []
            if let product = productSentence(label) { sentences.append(product) }
            let findings = assessment.findings
            if let lead = findings.first {
                sentences.append("\(lead.spoken), so it doesn't fit your \(lead.restriction.dietName).")
            }
            if findings.count > 1 {
                sentences.append("\(findings[1].spokenAsAlso).")
            }
            if let more = moreToWatchSentence(findings.count - 2) { sentences.append(more) }
            if let servings = servingsSentence(assessment.servingsPerContainer) { sentences.append(servings) }
            return sentences.joined(separator: " ")

        case .caution:
            var sentences: [String] = []
            if let product = productSentence(label) { sentences.append(product) }
            let findings = assessment.findings
            if findings.count >= 2, findings[0].subject == .serving, findings[1].subject == .serving {
                // Two per-serving numbers read as one sentence: "One serving
                // has 190 milligrams of sodium, about an eighth of your daily
                // limit, and 22 grams of carbohydrates, about half your meal
                // budget."
                sentences.append("\(findings[0].spoken), and \(findings[1].predicate).")
            } else {
                if let lead = findings.first { sentences.append("\(lead.spoken).") }
                if findings.count > 1 { sentences.append("\(findings[1].spokenAsAlso).") }
            }
            sentences.append("It's a moderate fit for your diet.")
            if let more = moreToWatchSentence(findings.count - 2) { sentences.append(more) }
            if let servings = servingsSentence(assessment.servingsPerContainer) { sentences.append(servings) }
            return sentences.joined(separator: " ")

        case .fits:
            var sentences: [String] = []
            if let product = productSentence(label) { sentences.append(product) }
            sentences.append(fitsSentence(label, profile))
            // Anything informational (e.g. the label doesn't list potassium)
            // still gets said, within the two-finding cap.
            for finding in assessment.findings.prefix(2) where finding.severity == .info {
                sentences.append("\(finding.spoken).")
            }
            if let servings = servingsSentence(assessment.servingsPerContainer) { sentences.append(servings) }
            return sentences.joined(separator: " ")
        }
    }

    /// "This is Cheerios." or nil when the name wasn't read.
    static func productSentence(_ label: FoodLabelResult) -> String? {
        guard let name = label.productName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        return "This is \(name)."
    }

    /// "It fits your diet — 10 milligrams of sodium per serving, and none of
    /// the ingredients you avoid."
    static func fitsSentence(_ label: FoodLabelResult, _ profile: DietaryProfile) -> String {
        var amounts: [String] = []
        let n = label.nutrients
        for restriction in profile.activeNutrientRestrictions {
            switch restriction {
            case .sodium: if let v = n.sodiumMg { amounts.append(quantity(v, .milligrams, of: "sodium")) }
            case .carbs: if let v = n.totalCarbohydrateG { amounts.append(quantity(v, .grams, of: "carbohydrates")) }
            case .saturatedFat: if let v = n.saturatedFatG { amounts.append(quantity(v, .grams, of: "saturated fat")) }
            case .potassium: if let v = n.potassiumMg { amounts.append(quantity(v, .milligrams, of: "potassium")) }
            case .gluten, .allergy, .avoid: break
            }
        }

        var reasons: [String] = []
        if !amounts.isEmpty { reasons.append("\(amounts.joined(separator: " and ")) per serving") }
        if profile.hasIngredientRestrictions { reasons.append("none of the ingredients you avoid") }

        guard !reasons.isEmpty else { return "It fits your diet." }
        return "It fits your diet — \(reasons.joined(separator: ", and "))."
    }

    /// "I could read most of this label, but the sodium wasn't legible. Try a
    /// closer photo of the Nutrition Facts panel."
    static func unknownScript(_ assessment: FitAssessment) -> String {
        let unreadable = assessment.findings.filter { $0.severity == .unreadable }
        var subjects: [String] = []
        var anyNutrient = false
        for finding in unreadable where !subjects.contains(finding.restriction.unreadableSubject) {
            subjects.append(finding.restriction.unreadableSubject)
            if finding.restriction.isNutrient { anyNutrient = true }
        }
        let plural = subjects.count > 1 || (unreadable.first?.restriction.unreadableSubjectIsPlural ?? false)
        let what = subjects.isEmpty ? "some of it" : joinedList(subjects)
        let verb = plural ? "weren't" : "wasn't"
        let panel = anyNutrient || subjects.isEmpty ? "Nutrition Facts panel" : "ingredients list"
        return "I could read most of this label, but \(what) \(verb) legible. Try a closer photo of the \(panel). Hold it about a foot from your face."
    }

    /// "And one more thing to watch — say 'what else' to hear it."
    static func moreToWatchSentence(_ remaining: Int) -> String? {
        guard remaining > 0 else { return nil }
        if remaining == 1 {
            return "And one more thing to watch — say 'what else' to hear it."
        }
        return "And \(spokenNumber(remaining)) more things to watch — say 'what else' to hear them."
    }

    /// "what else" — the findings the check didn't have room for.
    static func whatElseScript(_ assessment: FitAssessment?) -> String {
        guard let assessment else {
            return "I haven't checked a label yet. Say 'can I eat this' while holding the package up."
        }
        let remaining = assessment.findings.dropFirst(2)
        guard !remaining.isEmpty else { return "Nothing else to watch on this label." }
        return "Also: " + remaining.map { "\($0.spoken)." }.joined(separator: " ")
    }

    // MARK: - Question mode

    /// Answers from `nutrients` directly, with the comparison clause appended
    /// when the relevant restriction is active.
    static func questionScript(_ kind: FoodLabelCommand.QuestionKind, label: FoodLabelResult, profile: DietaryProfile) -> String {
        let n = label.nutrients
        switch kind {
        case .sodium:
            guard let sodium = n.sodiumMg else { return couldNotRead("the sodium") }
            var text = "\(quantity(sodium, .milligrams, of: "sodium")) per serving"
            if profile.lowSodium {
                text += " — that's \(fraction(sodium / max(profile.sodiumDailyLimitMg, 1), of: "your daily limit"))"
            }
            return text + "."

        case .sugar:
            guard n.totalSugarsG != nil || n.addedSugarsG != nil else { return couldNotRead("the sugar") }
            var text: String
            if let total = n.totalSugarsG {
                text = "\(quantity(total, .grams, of: "sugar")) per serving"
                if let added = n.addedSugarsG {
                    text += ", \(Int(added.rounded())) of them added"
                }
            } else {
                text = "\(quantity(n.addedSugarsG ?? 0, .grams, of: "added sugar")) per serving"
            }
            if profile.carbAware, let added = n.addedSugarsG {
                if added >= DietaryFitEvaluator.addedSugarHighG {
                    text += " — that's a lot of added sugar for your carb budget"
                } else if added >= DietaryFitEvaluator.addedSugarModerateG {
                    text += " — a moderate amount for your carb budget"
                }
            }
            return text + "."

        case .carbs:
            guard let carbs = n.totalCarbohydrateG else { return couldNotRead("the carbohydrates") }
            var text = "\(quantity(carbs, .grams, of: "carbohydrates")) per serving"
            if profile.carbAware {
                let target = max(profile.carbsPerMealG, 1)
                text += carbs > target
                    ? " — that's more than one meal's worth for your carb budget"
                    : " — that's \(fraction(carbs / target, of: "your meal budget"))"
            }
            return text + "."

        case .fat:
            guard n.totalFatG != nil || n.saturatedFatG != nil else { return couldNotRead("the fat") }
            var text: String
            if let fat = n.totalFatG {
                text = "\(quantity(fat, .grams, of: "fat")) per serving"
                if let sat = n.saturatedFatG {
                    text += ", \(Int(sat.rounded())) of them saturated"
                }
            } else {
                text = "\(quantity(n.saturatedFatG ?? 0, .grams, of: "saturated fat")) per serving"
            }
            if profile.lowSaturatedFat, let sat = n.saturatedFatG {
                text += " — that's \(fraction(sat / max(profile.saturatedFatDailyLimitG, 1), of: "your daily limit")) for saturated fat"
            }
            if let trans = n.transFatG, trans > 0 {
                text += ". It also has \(quantity(trans, .grams, of: "trans fat"))"
            }
            return text + "."

        case .contains(let word):
            return containsAnswer(word, label: label, profile: profile)

        case .expiration:
            return expirationScript(label)

        case .preparation:
            return preparationScript(label)

        case .whatElse:
            // Answered by the view model from the cached assessment.
            return whatElseScript(nil)
        }
    }

    /// "does this have peanuts" / "is there milk in this".
    static func containsAnswer(_ word: String, label: FoodLabelResult, profile: DietaryProfile) -> String {
        let spokenWord = spokenIngredient(word)
        let avoided = profile.cleanedAvoidList.contains { IngredientMatcher.normalize($0) == IngredientMatcher.normalize(word) }
        if let allergen = allergen(named: word) {
            let name = allergen.spokenName
            let allergic = profile.allergens.contains(allergen)
            switch IngredientMatcher.presence(of: allergen, in: label) {
            case .contains(let match)?:
                let found = spokenIngredient(match.keyword)
                let sameWord = IngredientMatcher.normalize(found).hasPrefix(IngredientMatcher.normalize(name))
                    || IngredientMatcher.normalize(name).hasPrefix(IngredientMatcher.normalize(found))
                var text = sameWord ? "Yes — it contains \(name)" : "Yes — it contains \(found), which is \(name)"
                if allergic {
                    text += ", and you're allergic to \(name)"
                } else if avoided {
                    text += ", which you avoid"
                }
                return text + "."
            case .mayContain?:
                var text = "The label says it may contain \(name)"
                if allergic { text += " — and you're allergic to \(name)" }
                return text + "."
            case nil:
                guard label.hasReadableIngredients else { return couldNotReadIngredients }
                return "I don't see \(name) in the ingredients."
            }
        }

        guard label.hasReadableIngredients || label.productName != nil else { return couldNotReadIngredients }
        if let match = IngredientMatcher.avoidMatch(word, in: label) {
            var text = "Yes — it contains \(spokenIngredient(match.source))"
            if avoided { text += ", which you avoid" }
            return text + "."
        }
        var advisories = IngredientMatcher.splitAdvisories(label.ingredients).advisories
        if let may = label.mayContainStatement { advisories.append(may) }
        if IngredientMatcher.containsSubstring(word, in: advisories) != nil {
            return "The label says it may contain \(spokenWord)."
        }
        return "I don't see \(spokenWord) in the ingredients."
    }

    /// The FDA-nine allergen a spoken word refers to, if any.
    static func allergen(named word: String) -> Allergen? {
        switch IngredientMatcher.normalize(word) {
        case "milk", "dairy", "lactose": return .milk
        case "egg", "eggs": return .eggs
        case "fish": return .fish
        case "shellfish", "shrimp", "crab", "lobster": return .shellfish
        case "tree nut", "tree nuts", "nuts", "almonds", "walnuts", "cashews", "pecans": return .treeNuts
        case "peanut", "peanuts": return .peanuts
        case "wheat": return .wheat
        case "soy", "soya", "soybean", "soybeans": return .soybeans
        case "sesame": return .sesame
        default: return nil
        }
    }

    private static let couldNotReadIngredients = "I couldn't read the ingredients on this label, so I can't tell."

    private static func couldNotRead(_ what: String) -> String {
        "I couldn't read \(what) on this label. Try a closer photo of the Nutrition Facts panel."
    }
}
