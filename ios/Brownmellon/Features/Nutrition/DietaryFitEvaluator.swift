import Foundation

/// One thing the rules noticed about a label, already phrased for speech.
struct Finding: Equatable {
    enum Severity: Int, Equatable, Comparable {
        // Declared most severe first; `<` follows this order.
        case high, moderate, info, unreadable

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Who the clause is about — decides the lead-in ("One serving has…",
    /// "It contains…", "The label doesn't list…").
    enum Subject: Equatable {
        /// A per-serving number; the predicate is the amount and comparison.
        case serving
        /// An ingredient; the predicate starts with its own verb ("contains…").
        case product
        /// The label itself ("doesn't list potassium").
        case label
        /// The predicate is already a whole clause ("the sodium wasn't legible").
        case none

        var leadIn: String {
            switch self {
            case .serving: return "One serving has"
            case .product: return "It"
            case .label: return "The label"
            case .none: return ""
            }
        }

        /// Lead-in for a second finding that follows another sentence.
        var alsoLeadIn: String {
            switch self {
            case .serving: return "It also has"
            case .product: return "It also"
            case .label: return "The label also"
            case .none: return "Also,"
            }
        }
    }

    let severity: Severity
    let restriction: DietaryRestriction
    let subject: Subject
    /// The clause minus its lead-in: "890 milligrams of sodium — that's more
    /// than half of your daily limit", "contains wheat, which you avoid".
    let predicate: String
    /// One clause, already phrased for speech: "One serving has 890 milligrams
    /// of sodium — that's more than half of your daily limit".
    let spoken: String

    init(severity: Severity, restriction: DietaryRestriction, subject: Subject, predicate: String) {
        self.severity = severity
        self.restriction = restriction
        self.subject = subject
        self.predicate = predicate
        self.spoken = Self.join(subject.leadIn, predicate)
    }

    /// "It also contains wheat, which you avoid"
    var spokenAsAlso: String { Self.join(subject.alsoLeadIn, predicate) }

    private static func join(_ leadIn: String, _ predicate: String) -> String {
        leadIn.isEmpty ? predicate : "\(leadIn) \(predicate)"
    }
}

/// What `DietaryFitEvaluator` concluded about one label for one profile.
struct FitAssessment: Equatable {
    enum Verdict: Equatable {
        case fits, caution, doesNotFit, unknown, noProfile, notALabel
    }

    let verdict: Verdict
    /// Ordered most severe first.
    let findings: [Finding]
    let servingsPerContainer: Double?
}

/// The on-device rules engine (PRD-food-label § 10d): compares a label's
/// per-serving numbers and ingredients to the wearer's own limits — not the
/// FDA's generic Daily Values — and says how well it fits. Pure Swift: no
/// UIKit, no networking, and the profile never leaves this process.
///
/// This is a comparison of label numbers to limits a person entered. It is
/// not medical advice, and the vocabulary reflects that: fits / moderate fit /
/// doesn't fit — never "safe", "healthy", or "you should".
enum DietaryFitEvaluator {
    // Thresholds from the PRD rules table, as fractions of the wearer's limit.
    static let sodiumHighFraction = 0.20
    static let sodiumModerateFraction = 0.10
    static let carbsModerateFraction = 0.50
    static let addedSugarHighG = 15.0
    static let addedSugarModerateG = 8.0
    static let saturatedFatHighFraction = 0.20
    static let saturatedFatModerateFraction = 0.10
    static let potassiumHighFraction = 0.15
    static let potassiumModerateFraction = 0.08

    static func evaluate(_ profile: DietaryProfile, _ label: FoodLabelResult) -> FitAssessment {
        guard label.found else {
            return FitAssessment(verdict: .notALabel, findings: [], servingsPerContainer: label.servingsPerContainer)
        }
        guard !profile.isEmpty else {
            return FitAssessment(verdict: .noProfile, findings: [], servingsPerContainer: label.servingsPerContainer)
        }

        var findings: [Finding] = []
        if profile.lowSodium { findings += sodiumFindings(profile, label) }
        if profile.carbAware { findings += carbFindings(profile, label) }
        if profile.lowSaturatedFat { findings += saturatedFatFindings(profile, label) }
        if profile.lowPotassium { findings += potassiumFindings(profile, label) }
        if profile.glutenFree { findings += glutenFindings(label) }
        for allergen in Allergen.allCases where profile.allergens.contains(allergen) {
            findings += allergyFindings(allergen, label)
        }
        for word in profile.cleanedAvoidList {
            findings += avoidFindings(word, label)
        }

        // Stable sort: severity first, evaluation order within a severity.
        let ordered = findings.enumerated()
            .sorted { a, b in
                a.element.severity != b.element.severity
                    ? a.element.severity < b.element.severity
                    : a.offset < b.offset
            }
            .map(\.element)

        return FitAssessment(
            verdict: verdict(for: ordered),
            findings: ordered,
            servingsPerContainer: label.servingsPerContainer
        )
    }

    /// Any high → doesNotFit; else any moderate → caution; else fits if every
    /// active restriction could be evaluated (info doesn't block), else unknown.
    static func verdict(for findings: [Finding]) -> FitAssessment.Verdict {
        if findings.contains(where: { $0.severity == .high }) { return .doesNotFit }
        if findings.contains(where: { $0.severity == .moderate }) { return .caution }
        if findings.contains(where: { $0.severity == .unreadable }) { return .unknown }
        return .fits
    }

    // MARK: - Nutrient rules

    private static func sodiumFindings(_ profile: DietaryProfile, _ label: FoodLabelResult) -> [Finding] {
        guard let sodium = label.nutrients.sodiumMg else {
            return [unreadable(.sodium)]
        }
        let ratio = sodium / max(profile.sodiumDailyLimitMg, 1)
        let amount = FoodLabelSpeech.quantity(sodium, .milligrams, of: "sodium")
        if ratio >= sodiumHighFraction {
            return [Finding(
                severity: .high, restriction: .sodium, subject: .serving,
                predicate: "\(amount) — that's \(FoodLabelSpeech.fraction(ratio, of: "your daily limit"))"
            )]
        }
        if ratio >= sodiumModerateFraction {
            return [Finding(
                severity: .moderate, restriction: .sodium, subject: .serving,
                predicate: "\(amount), \(FoodLabelSpeech.fraction(ratio, of: "your daily limit"))"
            )]
        }
        return []
    }

    private static func carbFindings(_ profile: DietaryProfile, _ label: FoodLabelResult) -> [Finding] {
        var findings: [Finding] = []
        let target = max(profile.carbsPerMealG, 1)

        if let carbs = label.nutrients.totalCarbohydrateG {
            let ratio = carbs / target
            let amount = FoodLabelSpeech.quantity(carbs, .grams, of: "carbohydrates")
            if carbs > target {
                findings.append(Finding(
                    severity: .high, restriction: .carbs, subject: .serving,
                    predicate: "\(amount) — that's more than one meal's worth"
                ))
            } else if ratio > carbsModerateFraction {
                findings.append(Finding(
                    severity: .moderate, restriction: .carbs, subject: .serving,
                    predicate: "\(amount), \(FoodLabelSpeech.fraction(ratio, of: "your meal budget"))"
                ))
            }
        } else {
            findings.append(unreadable(.carbs))
        }

        if let added = label.nutrients.addedSugarsG {
            let amount = FoodLabelSpeech.quantity(added, .grams, of: "added sugar")
            if added >= addedSugarHighG {
                findings.append(Finding(
                    severity: .high, restriction: .carbs, subject: .serving,
                    predicate: "\(amount) — that's a lot of sugar"
                ))
            } else if added >= addedSugarModerateG {
                findings.append(Finding(
                    severity: .moderate, restriction: .carbs, subject: .serving,
                    predicate: "\(amount), a moderate amount"
                ))
            }
        }
        return findings
    }

    private static func saturatedFatFindings(_ profile: DietaryProfile, _ label: FoodLabelResult) -> [Finding] {
        var findings: [Finding] = []

        if let trans = label.nutrients.transFatG, trans > 0 {
            findings.append(Finding(
                severity: .high, restriction: .saturatedFat, subject: .serving,
                predicate: "\(FoodLabelSpeech.quantity(trans, .grams, of: "trans fat")) — any trans fat is too much"
            ))
        }

        guard let sat = label.nutrients.saturatedFatG else {
            findings.append(unreadable(.saturatedFat))
            return findings
        }
        let ratio = sat / max(profile.saturatedFatDailyLimitG, 1)
        let amount = FoodLabelSpeech.quantity(sat, .grams, of: "saturated fat")
        if ratio >= saturatedFatHighFraction {
            findings.append(Finding(
                severity: .high, restriction: .saturatedFat, subject: .serving,
                predicate: "\(amount) — that's \(FoodLabelSpeech.fraction(ratio, of: "your daily limit"))"
            ))
        } else if ratio >= saturatedFatModerateFraction {
            findings.append(Finding(
                severity: .moderate, restriction: .saturatedFat, subject: .serving,
                predicate: "\(amount), \(FoodLabelSpeech.fraction(ratio, of: "your daily limit"))"
            ))
        }
        return findings
    }

    private static func potassiumFindings(_ profile: DietaryProfile, _ label: FoodLabelResult) -> [Finding] {
        var findings: [Finding] = []

        if let match = IngredientMatcher.phosphateMatch(in: label.ingredients) {
            findings.append(Finding(
                severity: .high, restriction: .potassium, subject: .product,
                predicate: "contains \(FoodLabelSpeech.spokenIngredient(match.source)), a phosphate additive"
            ))
        }

        guard let potassium = label.nutrients.potassiumMg else {
            // Potassium is optional on US labels, so a blank is information,
            // not a reason to call the whole check unknown.
            findings.append(Finding(
                severity: .info, restriction: .potassium, subject: .label,
                predicate: "doesn't list potassium"
            ))
            return findings
        }
        let ratio = potassium / max(profile.potassiumDailyLimitMg, 1)
        let amount = FoodLabelSpeech.quantity(potassium, .milligrams, of: "potassium")
        if ratio >= potassiumHighFraction {
            findings.append(Finding(
                severity: .high, restriction: .potassium, subject: .serving,
                predicate: "\(amount) — that's \(FoodLabelSpeech.fraction(ratio, of: "your daily limit"))"
            ))
        } else if ratio >= potassiumModerateFraction {
            findings.append(Finding(
                severity: .moderate, restriction: .potassium, subject: .serving,
                predicate: "\(amount), \(FoodLabelSpeech.fraction(ratio, of: "your daily limit"))"
            ))
        }
        return findings
    }

    // MARK: - Ingredient rules

    private static func glutenFindings(_ label: FoodLabelResult) -> [Finding] {
        guard label.hasReadableIngredients else { return [unreadable(.gluten)] }
        // A printed gluten-free claim overrides the keyword table — "wheat
        // starch" in a certified gluten-free product is processed to be safe
        // for the label's purposes, and the manufacturer is on the hook.
        if IngredientMatcher.hasGlutenFreeClaim(label.claims) { return [] }
        guard let match = IngredientMatcher.glutenMatch(in: label.ingredients) else { return [] }
        return [Finding(
            severity: .high, restriction: .gluten, subject: .product,
            predicate: "contains \(FoodLabelSpeech.spokenIngredient(match.keyword)), which has gluten"
        )]
    }

    private static func allergyFindings(_ allergen: Allergen, _ label: FoodLabelResult) -> [Finding] {
        guard label.hasReadableIngredients else { return [unreadable(.allergy)] }
        switch IngredientMatcher.presence(of: allergen, in: label) {
        case .contains(let match)?:
            return [Finding(
                severity: .high, restriction: .allergy, subject: .product,
                predicate: "contains \(allergenClause(match.keyword, allergen))"
            )]
        case .mayContain(let match)?:
            return [Finding(
                severity: .moderate, restriction: .allergy, subject: .product,
                predicate: "may contain \(allergenClause(match.keyword, allergen))"
            )]
        case nil:
            return []
        }
    }

    /// "peanuts, which you're allergic to" / "whey, which is milk — and you're
    /// allergic to milk".
    private static func allergenClause(_ keyword: String, _ allergen: Allergen) -> String {
        let name = allergen.spokenName
        let word = FoodLabelSpeech.spokenIngredient(keyword)
        if IngredientMatcher.normalize(word) == IngredientMatcher.normalize(name)
            || IngredientMatcher.normalize(word) == IngredientMatcher.normalize(name) + "s"
            || IngredientMatcher.normalize(word) + "s" == IngredientMatcher.normalize(name) {
            return "\(name), which you're allergic to"
        }
        return "\(word), which is \(name) — and you're allergic to \(name)"
    }

    private static func avoidFindings(_ word: String, _ label: FoodLabelResult) -> [Finding] {
        guard label.hasReadableIngredients || label.productName != nil else { return [unreadable(.avoid)] }
        guard IngredientMatcher.avoidMatch(word, in: label) != nil else { return [] }
        return [Finding(
            severity: .high, restriction: .avoid, subject: .product,
            predicate: "contains \(FoodLabelSpeech.spokenIngredient(word)), which you avoid"
        )]
    }

    private static func unreadable(_ restriction: DietaryRestriction) -> Finding {
        Finding(
            severity: .unreadable, restriction: restriction, subject: .none,
            predicate: restriction.unreadableClause
        )
    }
}
