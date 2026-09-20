import Foundation

/// Codable mirror of what `backend/api/food-label.ts` returns — one photo of a
/// packaged food, transcribed to numbers and lists (PRD-food-label § 10b).
///
/// Every nutrient is **per serving** and `nil` when the model couldn't read it
/// clearly: a missing sodium number is reported as unreadable, a wrong one
/// would be dangerous. Judgment (does this fit the diet?) happens on-device in
/// `DietaryFitEvaluator`, never here and never on the backend.
struct FoodLabelResult: Codable, Equatable {
    struct Nutrients: Codable, Equatable {
        var calories: Double?
        var totalFatG: Double?
        var saturatedFatG: Double?
        var transFatG: Double?
        var cholesterolMg: Double?
        var sodiumMg: Double?
        var totalCarbohydrateG: Double?
        var dietaryFiberG: Double?
        var totalSugarsG: Double?
        var addedSugarsG: Double?
        var proteinG: Double?
        var potassiumMg: Double?
        var phosphorusMg: Double?

        init(
            calories: Double? = nil,
            totalFatG: Double? = nil,
            saturatedFatG: Double? = nil,
            transFatG: Double? = nil,
            cholesterolMg: Double? = nil,
            sodiumMg: Double? = nil,
            totalCarbohydrateG: Double? = nil,
            dietaryFiberG: Double? = nil,
            totalSugarsG: Double? = nil,
            addedSugarsG: Double? = nil,
            proteinG: Double? = nil,
            potassiumMg: Double? = nil,
            phosphorusMg: Double? = nil
        ) {
            self.calories = calories
            self.totalFatG = totalFatG
            self.saturatedFatG = saturatedFatG
            self.transFatG = transFatG
            self.cholesterolMg = cholesterolMg
            self.sodiumMg = sodiumMg
            self.totalCarbohydrateG = totalCarbohydrateG
            self.dietaryFiberG = dietaryFiberG
            self.totalSugarsG = totalSugarsG
            self.addedSugarsG = addedSugarsG
            self.proteinG = proteinG
            self.potassiumMg = potassiumMg
            self.phosphorusMg = phosphorusMg
        }

        private enum CodingKeys: String, CodingKey {
            case calories, totalFatG, saturatedFatG, transFatG, cholesterolMg, sodiumMg
            case totalCarbohydrateG, dietaryFiberG, totalSugarsG, addedSugarsG, proteinG
            case potassiumMg, phosphorusMg
        }

        // `decodeIfPresent` so an omitted key reads the same as an explicit
        // null — both mean "not legible".
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            calories = try c.decodeIfPresent(Double.self, forKey: .calories)
            totalFatG = try c.decodeIfPresent(Double.self, forKey: .totalFatG)
            saturatedFatG = try c.decodeIfPresent(Double.self, forKey: .saturatedFatG)
            transFatG = try c.decodeIfPresent(Double.self, forKey: .transFatG)
            cholesterolMg = try c.decodeIfPresent(Double.self, forKey: .cholesterolMg)
            sodiumMg = try c.decodeIfPresent(Double.self, forKey: .sodiumMg)
            totalCarbohydrateG = try c.decodeIfPresent(Double.self, forKey: .totalCarbohydrateG)
            dietaryFiberG = try c.decodeIfPresent(Double.self, forKey: .dietaryFiberG)
            totalSugarsG = try c.decodeIfPresent(Double.self, forKey: .totalSugarsG)
            addedSugarsG = try c.decodeIfPresent(Double.self, forKey: .addedSugarsG)
            proteinG = try c.decodeIfPresent(Double.self, forKey: .proteinG)
            potassiumMg = try c.decodeIfPresent(Double.self, forKey: .potassiumMg)
            phosphorusMg = try c.decodeIfPresent(Double.self, forKey: .phosphorusMg)
        }
    }

    /// A food label (Nutrition Facts and/or ingredients) is visible.
    var found: Bool
    var productName: String?
    /// As printed, e.g. "1 cup (245g)".
    var servingSize: String?
    var servingsPerContainer: Double?
    var nutrients: Nutrients
    /// Split on top-level commas; sub-ingredients stay inside their parentheses.
    var ingredients: [String]
    /// "Contains: wheat, milk, soy" as printed.
    var containsStatement: String?
    var mayContainStatement: String?
    /// "gluten-free", "low sodium", "no added sugar"… as printed on the package.
    var claims: [String]
    /// Cooking/heating instructions if visible.
    var preparation: String?
    /// Best-by / use-by text as printed.
    var expiration: String?
    /// Everything legible, in reading order — "read everything".
    var fullText: String

    init(
        found: Bool,
        productName: String? = nil,
        servingSize: String? = nil,
        servingsPerContainer: Double? = nil,
        nutrients: Nutrients = Nutrients(),
        ingredients: [String] = [],
        containsStatement: String? = nil,
        mayContainStatement: String? = nil,
        claims: [String] = [],
        preparation: String? = nil,
        expiration: String? = nil,
        fullText: String = ""
    ) {
        self.found = found
        self.productName = productName
        self.servingSize = servingSize
        self.servingsPerContainer = servingsPerContainer
        self.nutrients = nutrients
        self.ingredients = ingredients
        self.containsStatement = containsStatement
        self.mayContainStatement = mayContainStatement
        self.claims = claims
        self.preparation = preparation
        self.expiration = expiration
        self.fullText = fullText
    }

    private enum CodingKeys: String, CodingKey {
        case found, productName, servingSize, servingsPerContainer, nutrients, ingredients
        case containsStatement, mayContainStatement, claims, preparation, expiration, fullText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        found = try c.decodeIfPresent(Bool.self, forKey: .found) ?? false
        productName = try c.decodeIfPresent(String.self, forKey: .productName)
        servingSize = try c.decodeIfPresent(String.self, forKey: .servingSize)
        servingsPerContainer = try c.decodeIfPresent(Double.self, forKey: .servingsPerContainer)
        nutrients = try c.decodeIfPresent(Nutrients.self, forKey: .nutrients) ?? Nutrients()
        ingredients = try c.decodeIfPresent([String].self, forKey: .ingredients) ?? []
        containsStatement = try c.decodeIfPresent(String.self, forKey: .containsStatement)
        mayContainStatement = try c.decodeIfPresent(String.self, forKey: .mayContainStatement)
        claims = try c.decodeIfPresent([String].self, forKey: .claims) ?? []
        preparation = try c.decodeIfPresent(String.self, forKey: .preparation)
        expiration = try c.decodeIfPresent(String.self, forKey: .expiration)
        fullText = try c.decodeIfPresent(String.self, forKey: .fullText) ?? ""
    }

    /// `true` when the ingredients list was legible enough to check anything
    /// against. A "Contains:" statement alone counts — it's what allergy rules
    /// read first.
    var hasReadableIngredients: Bool {
        !ingredients.isEmpty || !(containsStatement ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}
