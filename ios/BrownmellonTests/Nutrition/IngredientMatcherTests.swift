import XCTest
@testable import Brownmellon

/// The keyword tables behind gluten, allergen, phosphate and avoid-list
/// matching. Whole-word matching with plural tolerance, case- and
/// diacritic-insensitive, "may contain" kept separate from "contains".
final class IngredientMatcherTests: XCTestCase {
    // MARK: - Normalization

    func testNormalizeFoldsCaseDiacriticsAndPunctuation() {
        XCTAssertEqual(IngredientMatcher.normalize("  Crème Fraîche, (Cultured)!  "), "creme fraiche cultured")
        XCTAssertEqual(IngredientMatcher.tokens("Enriched WHEAT flour"), ["enriched", "wheat", "flour"])
    }

    // MARK: - Whole-word keyword matching

    func testMatchesWholeWordsWithPlurals() {
        XCTAssertTrue(IngredientMatcher.contains(keyword: "almond", in: "roasted almonds"))
        XCTAssertTrue(IngredientMatcher.contains(keyword: "peanut", in: "PEANUTS"))
        XCTAssertTrue(IngredientMatcher.contains(keyword: "anchovy", in: "anchovies"))
        XCTAssertTrue(IngredientMatcher.contains(keyword: "brewer's yeast", in: "Brewer's Yeast Extract"))
    }

    func testDoesNotMatchInsideOtherWords() {
        XCTAssertFalse(IngredientMatcher.contains(keyword: "egg", in: "eggplant"), "eggplant is not egg")
        XCTAssertFalse(IngredientMatcher.contains(keyword: "wheat", in: "buckwheat flour"), "buckwheat has no gluten")
        XCTAssertFalse(IngredientMatcher.contains(keyword: "nut", in: "coconut"))
        XCTAssertFalse(IngredientMatcher.contains(keyword: "soy", in: "soybean"), "different token — the table lists soybean itself")
    }

    // MARK: - Allergen tables

    func testWheyIsMilk() {
        let label = FoodLabelResult.label(ingredients: ["sugar", "whey", "salt"])
        XCTAssertEqual(
            IngredientMatcher.presence(of: .milk, in: label),
            .contains(IngredientMatcher.Match(keyword: "whey", source: "whey"))
        )
    }

    func testContainsStatementWithParentheticalTreeNuts() {
        let label = FoodLabelResult.label(ingredients: ["sugar"], contains: "Contains: tree nuts (almonds), soy.")
        guard case .contains(let match)? = IngredientMatcher.presence(of: .treeNuts, in: label) else {
            return XCTFail("tree nuts should be found in the Contains statement")
        }
        XCTAssertEqual(match.keyword, "tree nut")
        XCTAssertEqual(match.source, "tree nuts (almonds), soy")
        guard case .contains? = IngredientMatcher.presence(of: .soybeans, in: label) else {
            return XCTFail("soy should be found in the Contains statement")
        }
    }

    func testContainsStatementIsCheckedBeforeIngredients() {
        // Milk isn't in the ingredient words, but the manufacturer says so.
        let label = FoodLabelResult.label(ingredients: ["chocolate", "sugar"], contains: "Contains milk")
        guard case .contains(let match)? = IngredientMatcher.presence(of: .milk, in: label) else {
            return XCTFail("milk should be found")
        }
        XCTAssertEqual(match.keyword, "milk")
    }

    func testMayContainStatementIsMayContain() {
        let label = FoodLabelResult.label(ingredients: ["sugar"], mayContain: "May contain peanuts")
        guard case .mayContain(let match)? = IngredientMatcher.presence(of: .peanuts, in: label) else {
            return XCTFail("peanuts should be a may-contain")
        }
        XCTAssertEqual(match.keyword, "peanut")
    }

    func testMayContainFoldedIntoIngredientsIsStillAdvisory() {
        let label = FoodLabelResult.label(ingredients: ["sugar", "May contain traces of peanuts"])
        guard case .mayContain? = IngredientMatcher.presence(of: .peanuts, in: label) else {
            return XCTFail("an advisory entry in the ingredient list is a may-contain, not a contains")
        }
        let split = IngredientMatcher.splitAdvisories(label.ingredients)
        XCTAssertEqual(split.ingredients, ["sugar"])
        XCTAssertEqual(split.advisories, ["May contain traces of peanuts"])
    }

    func testContainsWinsOverMayContain() {
        let label = FoodLabelResult.label(ingredients: ["peanut oil"], mayContain: "May contain peanuts")
        guard case .contains? = IngredientMatcher.presence(of: .peanuts, in: label) else {
            return XCTFail("an actual ingredient outranks the advisory")
        }
    }

    func testAbsentAllergenIsNil() {
        let label = FoodLabelResult.label(ingredients: ["green beans", "water"])
        XCTAssertNil(IngredientMatcher.presence(of: .peanuts, in: label))
        XCTAssertNil(IngredientMatcher.presence(of: .milk, in: label))
    }

    func testEveryAllergenHasAtLeastItsOwnName() {
        for allergen in Allergen.allCases {
            let label = FoodLabelResult.label(ingredients: [allergen.spokenName])
            XCTAssertNotNil(IngredientMatcher.presence(of: allergen, in: label), "\(allergen) should match its own name")
        }
    }

    // MARK: - Diacritics

    func testDiacriticsAreIgnoredInSubstringMatch() {
        let label = FoodLabelResult.label(ingredients: ["Crème fraîche", "sel"])
        XCTAssertNotNil(IngredientMatcher.avoidMatch("creme fraiche", in: label))
        XCTAssertNotNil(IngredientMatcher.avoidMatch("CRÈME", in: label))
    }

    func testDiacriticsAreIgnoredInKeywordMatch() {
        XCTAssertTrue(IngredientMatcher.contains(keyword: "sesame", in: "sésame grillé"))
    }

    // MARK: - Gluten

    func testGlutenKeywordsAreFound() {
        for grain in ["wheat", "barley", "rye", "malt", "spelt", "semolina", "durum", "farro", "triticale", "brewer's yeast"] {
            XCTAssertNotNil(IngredientMatcher.glutenMatch(in: ["water", grain]), "\(grain) should be gluten")
        }
    }

    func testGlutenFreeClaimSpellings() {
        XCTAssertTrue(IngredientMatcher.hasGlutenFreeClaim(["Gluten-Free"]))
        XCTAssertTrue(IngredientMatcher.hasGlutenFreeClaim(["certified gluten free"]))
        XCTAssertFalse(IngredientMatcher.hasGlutenFreeClaim(["Low Sodium"]))
        XCTAssertFalse(IngredientMatcher.hasGlutenFreeClaim([]))
    }

    // MARK: - Phosphate

    func testPhosphateAdditivesAreFound() {
        XCTAssertNotNil(IngredientMatcher.phosphateMatch(in: ["sodium phosphate"]))
        XCTAssertNotNil(IngredientMatcher.phosphateMatch(in: ["tripotassium phosphate"]))
        XCTAssertNotNil(IngredientMatcher.phosphateMatch(in: ["phosphoric acid"]))
        XCTAssertNil(IngredientMatcher.phosphateMatch(in: ["green beans", "water"]))
    }

    // MARK: - Avoid list (substring)

    func testAvoidMatchesSubstringsInIngredientsAndProductName() {
        let label = FoodLabelResult.label(name: "Diet Cola", ingredients: ["carbonated water", "aspartame", "caffeine"])
        XCTAssertNotNil(IngredientMatcher.avoidMatch("aspartame", in: label))
        XCTAssertNotNil(IngredientMatcher.avoidMatch("cola", in: label), "product name counts")
        XCTAssertNotNil(IngredientMatcher.avoidMatch("caffein", in: label), "substring, per the PRD")
        XCTAssertNil(IngredientMatcher.avoidMatch("grapefruit", in: label))
    }

    func testAvoidIgnoresAdvisoryEntries() {
        let label = FoodLabelResult.label(name: "Cookies", ingredients: ["flour", "May contain peanuts"])
        XCTAssertNil(IngredientMatcher.avoidMatch("peanut", in: label), "an advisory isn't the ingredient itself")
    }

    // MARK: - Contains statement lead-in

    func testStripContainsLeadIn() {
        XCTAssertEqual(IngredientMatcher.stripContainsLeadIn("Contains: wheat, milk, soy."), "wheat, milk, soy")
        XCTAssertEqual(IngredientMatcher.stripContainsLeadIn("CONTAINS WHEAT"), "WHEAT")
        XCTAssertNil(IngredientMatcher.stripContainsLeadIn("Contains:"))
        XCTAssertNil(IngredientMatcher.stripContainsLeadIn(nil))
    }
}
