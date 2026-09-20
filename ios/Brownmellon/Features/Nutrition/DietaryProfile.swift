import Foundation

/// The FDA's nine major food allergens — the set a caregiver can pick from in
/// Diet Setup (PRD-food-label § 10a).
enum Allergen: String, Codable, CaseIterable, Identifiable, Equatable, Hashable {
    case milk, eggs, fish, shellfish, treeNuts, peanuts, wheat, soybeans, sesame

    var id: String { rawValue }

    /// How the allergen is named on screen and out loud.
    var spokenName: String {
        switch self {
        case .milk: return "milk"
        case .eggs: return "eggs"
        case .fish: return "fish"
        case .shellfish: return "shellfish"
        case .treeNuts: return "tree nuts"
        case .peanuts: return "peanuts"
        case .wheat: return "wheat"
        case .soybeans: return "soy"
        case .sesame: return "sesame"
        }
    }
}

/// Which diet rule a finding or an unreadable field belongs to. Drives the
/// spoken verdict ("doesn't fit your low-sodium diet") and lets the speech
/// layer tell nutrient findings ("one serving has …") from ingredient
/// findings ("it contains …").
enum DietaryRestriction: String, Codable, Equatable, CaseIterable {
    case sodium, carbs, saturatedFat, potassium, gluten, allergy, avoid

    /// True for the rules that compare a Nutrition Facts number to a limit.
    var isNutrient: Bool {
        switch self {
        case .sodium, .carbs, .saturatedFat, .potassium: return true
        case .gluten, .allergy, .avoid: return false
        }
    }

    /// "…so it doesn't fit your <dietName>."
    var dietName: String {
        switch self {
        case .sodium: return "low-sodium diet"
        case .carbs: return "carb budget"
        case .saturatedFat: return "low-saturated-fat diet"
        case .potassium: return "low-potassium diet"
        case .gluten: return "gluten-free diet"
        case .allergy, .avoid: return "diet"
        }
    }

    /// The label field this rule reads — named the way the wearer hears it
    /// when it wasn't legible ("the sodium wasn't legible").
    var unreadableSubject: String {
        switch self {
        case .sodium: return "the sodium"
        case .carbs: return "the carbohydrates"
        case .saturatedFat: return "the saturated fat"
        case .potassium: return "the potassium"
        case .gluten, .allergy, .avoid: return "the ingredients"
        }
    }

    /// Whether `unreadableSubject` takes a plural verb.
    var unreadableSubjectIsPlural: Bool {
        switch self {
        case .carbs, .gluten, .allergy, .avoid: return true
        case .sodium, .saturatedFat, .potassium: return false
        }
    }

    /// "the sodium wasn't legible" / "the ingredients weren't legible".
    var unreadableClause: String {
        "\(unreadableSubject) \(unreadableSubjectIsPlural ? "weren't" : "wasn't") legible"
    }
}

/// The caregiver's diet rules for the wearer (PRD-food-label § 10a). Every
/// restriction is a switch with an editable limit where one applies; defaults
/// come from standard guidance so a caregiver can just flip the switch.
///
/// This is health-adjacent personal data: it is stored on-device only via
/// `SecureLocalStore` and is **never** included in any network request — the
/// backend sees a photo and returns numbers; the comparison runs here.
struct DietaryProfile: Codable, Equatable {
    static let storageKey = "dietaryProfile"

    // Defaults per the PRD table.
    static let defaultSodiumDailyLimitMg: Double = 1500
    static let defaultCarbsPerMealG: Double = 45
    static let defaultSaturatedFatDailyLimitG: Double = 13
    static let defaultPotassiumDailyLimitMg: Double = 2000

    var lowSodium = false
    var sodiumDailyLimitMg = DietaryProfile.defaultSodiumDailyLimitMg

    var carbAware = false
    var carbsPerMealG = DietaryProfile.defaultCarbsPerMealG

    var lowSaturatedFat = false
    var saturatedFatDailyLimitG = DietaryProfile.defaultSaturatedFatDailyLimitG

    var lowPotassium = false
    var potassiumDailyLimitMg = DietaryProfile.defaultPotassiumDailyLimitMg

    var glutenFree = false

    var allergens: Set<Allergen> = []

    /// Free-text words matched as substrings against the ingredients and the
    /// product name (e.g. "grapefruit", "alcohol", "aspartame").
    var avoidIngredients: [String] = []

    init() {}

    /// Nothing switched on — check mode reports `noProfile`.
    var isEmpty: Bool {
        !lowSodium && !carbAware && !lowSaturatedFat && !lowPotassium && !glutenFree
            && allergens.isEmpty && cleanedAvoidList.isEmpty
    }

    /// Avoid words trimmed and de-duplicated, blanks dropped.
    var cleanedAvoidList: [String] {
        var seen = Set<String>()
        return avoidIngredients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Restrictions that read a Nutrition Facts number, in the order they're
    /// spoken.
    var activeNutrientRestrictions: [DietaryRestriction] {
        var active: [DietaryRestriction] = []
        if lowSodium { active.append(.sodium) }
        if carbAware { active.append(.carbs) }
        if lowSaturatedFat { active.append(.saturatedFat) }
        if lowPotassium { active.append(.potassium) }
        return active
    }

    /// True when any rule reads the ingredients list.
    var hasIngredientRestrictions: Bool {
        glutenFree || !allergens.isEmpty || !cleanedAvoidList.isEmpty
    }

    // Tolerant decoding: a profile saved by an older build with fewer fields
    // still loads, and missing limits fall back to the defaults.
    private enum CodingKeys: String, CodingKey {
        case lowSodium, sodiumDailyLimitMg, carbAware, carbsPerMealG
        case lowSaturatedFat, saturatedFatDailyLimitG, lowPotassium, potassiumDailyLimitMg
        case glutenFree, allergens, avoidIngredients
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lowSodium = try c.decodeIfPresent(Bool.self, forKey: .lowSodium) ?? false
        sodiumDailyLimitMg = try c.decodeIfPresent(Double.self, forKey: .sodiumDailyLimitMg) ?? Self.defaultSodiumDailyLimitMg
        carbAware = try c.decodeIfPresent(Bool.self, forKey: .carbAware) ?? false
        carbsPerMealG = try c.decodeIfPresent(Double.self, forKey: .carbsPerMealG) ?? Self.defaultCarbsPerMealG
        lowSaturatedFat = try c.decodeIfPresent(Bool.self, forKey: .lowSaturatedFat) ?? false
        saturatedFatDailyLimitG = try c.decodeIfPresent(Double.self, forKey: .saturatedFatDailyLimitG) ?? Self.defaultSaturatedFatDailyLimitG
        lowPotassium = try c.decodeIfPresent(Bool.self, forKey: .lowPotassium) ?? false
        potassiumDailyLimitMg = try c.decodeIfPresent(Double.self, forKey: .potassiumDailyLimitMg) ?? Self.defaultPotassiumDailyLimitMg
        glutenFree = try c.decodeIfPresent(Bool.self, forKey: .glutenFree) ?? false
        allergens = try c.decodeIfPresent(Set<Allergen>.self, forKey: .allergens) ?? []
        avoidIngredients = try c.decodeIfPresent([String].self, forKey: .avoidIngredients) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lowSodium, forKey: .lowSodium)
        try c.encode(sodiumDailyLimitMg, forKey: .sodiumDailyLimitMg)
        try c.encode(carbAware, forKey: .carbAware)
        try c.encode(carbsPerMealG, forKey: .carbsPerMealG)
        try c.encode(lowSaturatedFat, forKey: .lowSaturatedFat)
        try c.encode(saturatedFatDailyLimitG, forKey: .saturatedFatDailyLimitG)
        try c.encode(lowPotassium, forKey: .lowPotassium)
        try c.encode(potassiumDailyLimitMg, forKey: .potassiumDailyLimitMg)
        try c.encode(glutenFree, forKey: .glutenFree)
        // Sorted so the encoding is stable (Set order isn't).
        try c.encode(allergens.sorted { $0.rawValue < $1.rawValue }, forKey: .allergens)
        try c.encode(avoidIngredients, forKey: .avoidIngredients)
    }
}
