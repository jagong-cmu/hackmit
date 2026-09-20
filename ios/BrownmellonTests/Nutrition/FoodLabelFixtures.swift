import Foundation
import XCTest
@testable import Brownmellon

/// Hand-written `FoodLabelResult` fixtures (Fixtures/*.json) — what the
/// backend would return for a high-sodium soup, a cereal, a no-salt-added
/// vegetable, a label the model half-read, and something that isn't a label.
enum FoodLabelFixtures {
    static func load(_ name: String) throws -> FoodLabelResult {
        let bundle = Bundle(for: FixtureToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw FixtureError.missing(name)
        }
        return try JSONDecoder().decode(FoodLabelResult.self, from: Data(contentsOf: url))
    }

    static func soup() throws -> FoodLabelResult { try load("soup") }
    static func cereal() throws -> FoodLabelResult { try load("cereal") }
    static func beans() throws -> FoodLabelResult { try load("beans") }
    static func unreadable() throws -> FoodLabelResult { try load("unreadable") }
    static func notALabel() throws -> FoodLabelResult { try load("not-a-label") }

    enum FixtureError: Error {
        case missing(String)
    }

    private final class FixtureToken {}
}

/// Profiles the tests reuse.
extension DietaryProfile {
    /// The demo profile from the PRD: low sodium plus a peanut allergy.
    static var lowSodiumPeanutAllergy: DietaryProfile {
        var profile = DietaryProfile()
        profile.lowSodium = true
        profile.allergens = [.peanuts]
        return profile
    }

    static var lowSodiumOnly: DietaryProfile {
        var profile = DietaryProfile()
        profile.lowSodium = true
        return profile
    }

    static var carbAwareOnly: DietaryProfile {
        var profile = DietaryProfile()
        profile.carbAware = true
        return profile
    }

    static var lowSaturatedFatOnly: DietaryProfile {
        var profile = DietaryProfile()
        profile.lowSaturatedFat = true
        return profile
    }

    static var lowPotassiumOnly: DietaryProfile {
        var profile = DietaryProfile()
        profile.lowPotassium = true
        return profile
    }

    static var glutenFreeOnly: DietaryProfile {
        var profile = DietaryProfile()
        profile.glutenFree = true
        return profile
    }

    static func allergy(_ allergens: Allergen...) -> DietaryProfile {
        var profile = DietaryProfile()
        profile.allergens = Set(allergens)
        return profile
    }

    static func avoiding(_ words: String...) -> DietaryProfile {
        var profile = DietaryProfile()
        profile.avoidIngredients = words
        return profile
    }
}

/// Builds labels inline for the rules-table tests.
extension FoodLabelResult {
    static func label(
        name: String? = "Test Food",
        servings: Double? = nil,
        sodium: Double? = nil,
        carbs: Double? = nil,
        addedSugars: Double? = nil,
        saturatedFat: Double? = nil,
        transFat: Double? = nil,
        potassium: Double? = nil,
        ingredients: [String] = ["water", "salt"],
        contains: String? = nil,
        mayContain: String? = nil,
        claims: [String] = []
    ) -> FoodLabelResult {
        FoodLabelResult(
            found: true,
            productName: name,
            servingSize: "1 cup",
            servingsPerContainer: servings,
            nutrients: Nutrients(
                saturatedFatG: saturatedFat,
                transFatG: transFat,
                sodiumMg: sodium,
                totalCarbohydrateG: carbs,
                addedSugarsG: addedSugars,
                potassiumMg: potassium
            ),
            ingredients: ingredients,
            containsStatement: contains,
            mayContainStatement: mayContain,
            claims: claims,
            fullText: "test"
        )
    }
}
