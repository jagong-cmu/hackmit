import XCTest
@testable import Brownmellon

/// One test per cell of the PRD's rules table (§ 10d), plus aggregation. The
/// evaluator is pure Swift — no UIKit, no networking — and compares each
/// per-serving number to the wearer's *own* limit, not a generic Daily Value.
final class DietaryFitEvaluatorTests: XCTestCase {
    private func evaluate(_ profile: DietaryProfile, _ label: FoodLabelResult) -> FitAssessment {
        DietaryFitEvaluator.evaluate(profile, label)
    }

    private func severities(_ assessment: FitAssessment, _ restriction: DietaryRestriction) -> [Finding.Severity] {
        assessment.findings.filter { $0.restriction == restriction }.map(\.severity)
    }

    // MARK: - Low sodium (daily limit 1500 mg)

    func testSodiumAtOrAbove20PercentOfLimitIsHigh() {
        let a = evaluate(.lowSodiumOnly, .label(sodium: 300))   // exactly 20%
        XCTAssertEqual(a.verdict, .doesNotFit)
        XCTAssertEqual(severities(a, .sodium), [.high])
        XCTAssertEqual(a.findings[0].spoken, "One serving has 300 milligrams of sodium — that's about a fifth of your daily limit")
    }

    func testSodiumBetween10And20PercentIsModerate() {
        let a = evaluate(.lowSodiumOnly, .label(sodium: 190))   // 12.7%
        XCTAssertEqual(a.verdict, .caution)
        XCTAssertEqual(severities(a, .sodium), [.moderate])
        XCTAssertEqual(a.findings[0].spoken, "One serving has 190 milligrams of sodium, about an eighth of your daily limit")
    }

    func testSodiumBelow10PercentIsNoFinding() {
        let a = evaluate(.lowSodiumOnly, .label(sodium: 10))
        XCTAssertEqual(a.verdict, .fits)
        XCTAssertTrue(a.findings.isEmpty)
    }

    func testSodiumNilIsUnreadable() {
        let a = evaluate(.lowSodiumOnly, .label(sodium: nil))
        XCTAssertEqual(a.verdict, .unknown)
        XCTAssertEqual(severities(a, .sodium), [.unreadable])
        XCTAssertEqual(a.findings[0].spoken, "the sodium wasn't legible")
    }

    func testSodiumUsesTheWearersOwnLimit() {
        var profile = DietaryProfile.lowSodiumOnly
        profile.sodiumDailyLimitMg = 2300
        // 300 mg is 20% of 1500 (high) but only 13% of 2300 (moderate).
        XCTAssertEqual(evaluate(profile, .label(sodium: 300)).verdict, .caution)
    }

    // MARK: - Carb-aware (45 g per meal)

    func testCarbsOverMealTargetIsHigh() {
        let a = evaluate(.carbAwareOnly, .label(carbs: 46))
        XCTAssertEqual(a.verdict, .doesNotFit)
        XCTAssertEqual(severities(a, .carbs), [.high])
        XCTAssertEqual(a.findings[0].spoken, "One serving has 46 grams of carbohydrates — that's more than one meal's worth")
    }

    func testAddedSugarsAtOrAbove15GramsIsHigh() {
        let a = evaluate(.carbAwareOnly, .label(carbs: 20, addedSugars: 15))
        XCTAssertEqual(a.verdict, .doesNotFit)
        XCTAssertEqual(severities(a, .carbs), [.high])
        XCTAssertTrue(a.findings[0].spoken.contains("15 grams of added sugar"))
    }

    func testCarbsOverHalfOfTargetIsModerate() {
        let a = evaluate(.carbAwareOnly, .label(carbs: 30))   // 67%
        XCTAssertEqual(a.verdict, .caution)
        XCTAssertEqual(severities(a, .carbs), [.moderate])
        XCTAssertEqual(a.findings[0].spoken, "One serving has 30 grams of carbohydrates, more than half your meal budget")
    }

    func testAddedSugarsBetween8And15GramsIsModerate() {
        let a = evaluate(.carbAwareOnly, .label(carbs: 12, addedSugars: 8))
        XCTAssertEqual(a.verdict, .caution)
        XCTAssertEqual(severities(a, .carbs), [.moderate])
        XCTAssertEqual(a.findings[0].spoken, "One serving has 8 grams of added sugar, a moderate amount")
    }

    func testAddedSugarsBelow8GramsWithLowCarbsFits() {
        XCTAssertEqual(evaluate(.carbAwareOnly, .label(carbs: 12, addedSugars: 7)).verdict, .fits)
    }

    func testCarbsNilIsUnreadableEvenWhenSugarsRead() {
        let a = evaluate(.carbAwareOnly, .label(carbs: nil, addedSugars: 2))
        XCTAssertEqual(a.verdict, .unknown)
        XCTAssertEqual(severities(a, .carbs), [.unreadable])
        XCTAssertEqual(a.findings[0].spoken, "the carbohydrates weren't legible")
    }

    func testHighAddedSugarsStillDecidesWhenCarbsUnreadable() {
        let a = evaluate(.carbAwareOnly, .label(carbs: nil, addedSugars: 20))
        XCTAssertEqual(a.verdict, .doesNotFit, "a high finding decides; the unreadable one is still reported")
        XCTAssertEqual(severities(a, .carbs), [.high, .unreadable])
    }

    // MARK: - Low saturated fat (13 g daily)

    func testSaturatedFatAtOrAbove20PercentIsHigh() {
        let a = evaluate(.lowSaturatedFatOnly, .label(saturatedFat: 3, transFat: 0))   // 23%
        XCTAssertEqual(a.verdict, .doesNotFit)
        XCTAssertEqual(severities(a, .saturatedFat), [.high])
        XCTAssertEqual(a.findings[0].spoken, "One serving has 3 grams of saturated fat — that's about a quarter of your daily limit")
    }

    func testAnyTransFatIsHigh() {
        let a = evaluate(.lowSaturatedFatOnly, .label(saturatedFat: 0.5, transFat: 0.5))
        XCTAssertEqual(a.verdict, .doesNotFit)
        XCTAssertEqual(severities(a, .saturatedFat), [.high])
        XCTAssertEqual(a.findings[0].spoken, "One serving has 1 gram of trans fat — any trans fat is too much")
    }

    func testSaturatedFatBetween10And20PercentIsModerate() {
        let a = evaluate(.lowSaturatedFatOnly, .label(saturatedFat: 2, transFat: 0))   // 15%
        XCTAssertEqual(a.verdict, .caution)
        XCTAssertEqual(severities(a, .saturatedFat), [.moderate])
    }

    func testSaturatedFatNilIsUnreadable() {
        let a = evaluate(.lowSaturatedFatOnly, .label(saturatedFat: nil, transFat: 0))
        XCTAssertEqual(a.verdict, .unknown)
        XCTAssertEqual(severities(a, .saturatedFat), [.unreadable])
    }

    func testZeroTransFatAndLowSaturatedFatFits() {
        XCTAssertEqual(evaluate(.lowSaturatedFatOnly, .label(saturatedFat: 0.5, transFat: 0)).verdict, .fits)
    }

    // MARK: - Low potassium (2000 mg daily)

    func testPotassiumAtOrAbove15PercentIsHigh() {
        let a = evaluate(.lowPotassiumOnly, .label(potassium: 300))   // 15%
        XCTAssertEqual(a.verdict, .doesNotFit)
        XCTAssertEqual(severities(a, .potassium), [.high])
    }

    func testPhosphateInIngredientsIsHigh() {
        let a = evaluate(.lowPotassiumOnly, .label(potassium: 50, ingredients: ["water", "sodium phosphate", "salt"]))
        XCTAssertEqual(a.verdict, .doesNotFit)
        XCTAssertEqual(severities(a, .potassium), [.high])
        XCTAssertEqual(a.findings[0].spoken, "It contains sodium phosphate, a phosphate additive")
    }

    func testPotassiumBetween8And15PercentIsModerate() {
        let a = evaluate(.lowPotassiumOnly, .label(potassium: 200))   // 10%
        XCTAssertEqual(a.verdict, .caution)
        XCTAssertEqual(severities(a, .potassium), [.moderate])
    }

    func testPotassiumNilIsInfoNotUnreadable() {
        let a = evaluate(.lowPotassiumOnly, .label(potassium: nil))
        XCTAssertEqual(a.verdict, .fits, "potassium is optional on US labels; a blank is information, not a failed check")
        XCTAssertEqual(severities(a, .potassium), [.info])
        XCTAssertEqual(a.findings[0].spoken, "The label doesn't list potassium")
    }

    // MARK: - Gluten-free

    func testGlutenKeywordIsHigh() {
        let a = evaluate(.glutenFreeOnly, .label(ingredients: ["rice", "malt extract", "salt"]))
        XCTAssertEqual(a.verdict, .doesNotFit)
        XCTAssertEqual(severities(a, .gluten), [.high])
        XCTAssertEqual(a.findings[0].spoken, "It contains malt, which has gluten")
    }

    func testGlutenFreeClaimOverridesKeyword() {
        let a = evaluate(.glutenFreeOnly, .label(ingredients: ["wheat starch", "salt"], claims: ["Certified Gluten-Free"]))
        XCTAssertEqual(a.verdict, .fits)
        XCTAssertTrue(a.findings.isEmpty)
    }

    func testGlutenWithNoIngredientsReadIsUnreadable() {
        let a = evaluate(.glutenFreeOnly, .label(ingredients: []))
        XCTAssertEqual(a.verdict, .unknown)
        XCTAssertEqual(severities(a, .gluten), [.unreadable])
        XCTAssertEqual(a.findings[0].spoken, "the ingredients weren't legible")
    }

    func testBuckwheatIsNotGluten() {
        XCTAssertEqual(evaluate(.glutenFreeOnly, .label(ingredients: ["buckwheat flour", "water"])).verdict, .fits)
    }

    func testWheatInContainsStatementIsGlutenEvenWhenIngredientsDidNotRead() {
        // The ingredient list was illegible but the manufacturer's allergen
        // summary says wheat — that must not come back as "fits".
        let a = evaluate(.glutenFreeOnly, .label(ingredients: [], contains: "Contains: wheat, milk"))
        XCTAssertEqual(a.verdict, .doesNotFit)
        XCTAssertEqual(severities(a, .gluten), [.high])
        XCTAssertEqual(a.findings[0].spoken, "It contains wheat, which has gluten")
    }

    func testWheatInContainsStatementIsGlutenWhenIngredientsNameItIndirectly() {
        let a = evaluate(.glutenFreeOnly, .label(ingredients: ["enriched flour", "sugar", "salt"], contains: "Contains: wheat"))
        XCTAssertEqual(a.verdict, .doesNotFit)
        XCTAssertEqual(severities(a, .gluten), [.high])
    }

    func testContainsStatementWithoutWheatCannotClearGluten() {
        // "Contains:" lists only the FDA nine — it says nothing about barley,
        // rye or malt, so with no ingredient list the check is still unreadable.
        let a = evaluate(.glutenFreeOnly, .label(ingredients: [], contains: "Contains: milk"))
        XCTAssertEqual(a.verdict, .unknown)
        XCTAssertEqual(severities(a, .gluten), [.unreadable])
    }

    func testGlutenFreeClaimDecidesEvenWhenIngredientsDidNotRead() {
        let a = evaluate(.glutenFreeOnly, .label(ingredients: [], claims: ["Gluten Free"]))
        XCTAssertEqual(a.verdict, .fits, "the claim is the big print; it answers the question on its own")
        XCTAssertTrue(a.findings.isEmpty)
    }

    // MARK: - Allergies

    func testAllergenInContainsStatementIsHigh() {
        let a = evaluate(.allergy(.peanuts), .label(ingredients: ["sugar", "oil"], contains: "Contains: peanuts, milk"))
        XCTAssertEqual(a.verdict, .doesNotFit)
        XCTAssertEqual(severities(a, .allergy), [.high])
        XCTAssertEqual(a.findings[0].spoken, "It contains peanuts, which you're allergic to")
    }

    func testAllergenInIngredientKeywordsIsHigh() {
        let a = evaluate(.allergy(.milk), .label(ingredients: ["sugar", "whey protein", "salt"]))
        XCTAssertEqual(a.verdict, .doesNotFit)
        XCTAssertEqual(a.findings[0].spoken, "It contains whey, which is milk — and you're allergic to milk")
    }

    func testAllergenOnlyInMayContainIsModerate() {
        let a = evaluate(.allergy(.peanuts), .label(ingredients: ["sugar", "oil"], mayContain: "May contain peanuts and tree nuts"))
        XCTAssertEqual(a.verdict, .caution)
        XCTAssertEqual(severities(a, .allergy), [.moderate])
        XCTAssertEqual(a.findings[0].spoken, "It may contain peanuts, which you're allergic to")
    }

    func testAllergyWithNoIngredientsReadIsUnreadable() {
        let a = evaluate(.allergy(.peanuts), .label(ingredients: []))
        XCTAssertEqual(a.verdict, .unknown)
        XCTAssertEqual(severities(a, .allergy), [.unreadable])
    }

    func testAllergenAbsentFits() {
        XCTAssertEqual(evaluate(.allergy(.peanuts), .label(ingredients: ["green beans", "water"])).verdict, .fits)
    }

    // MARK: - Avoid list

    func testAvoidWordInIngredientsIsHigh() {
        let a = evaluate(.avoiding("grapefruit"), .label(ingredients: ["water", "Grapefruit juice concentrate"]))
        XCTAssertEqual(a.verdict, .doesNotFit)
        XCTAssertEqual(severities(a, .avoid), [.high])
        XCTAssertEqual(a.findings[0].spoken, "It contains grapefruit, which you avoid")
    }

    func testAvoidWordInProductNameIsHigh() {
        let a = evaluate(.avoiding("grapefruit"), .label(name: "Ruby Red Grapefruit Soda", ingredients: ["carbonated water", "sugar"]))
        XCTAssertEqual(a.verdict, .doesNotFit)
    }

    func testAvoidWithNothingReadIsUnreadable() {
        let a = evaluate(.avoiding("grapefruit"), .label(name: nil, ingredients: []))
        XCTAssertEqual(a.verdict, .unknown)
        XCTAssertEqual(severities(a, .avoid), [.unreadable])
    }

    func testAvoidWithProductNameButNoIngredientsIsStillUnreadable() {
        // Reading the name off the front doesn't tell us what's inside: a
        // statin patient avoiding grapefruit must not hear "fits" here.
        let a = evaluate(.avoiding("grapefruit"), .label(name: "Citrus Blend Juice", ingredients: []))
        XCTAssertEqual(a.verdict, .unknown)
        XCTAssertEqual(severities(a, .avoid), [.unreadable])
    }

    func testAvoidWordInProductNameIsHighEvenWhenIngredientsDidNotRead() {
        let a = evaluate(.avoiding("grapefruit"), .label(name: "Ruby Red Grapefruit Soda", ingredients: []))
        XCTAssertEqual(a.verdict, .doesNotFit)
        XCTAssertEqual(severities(a, .avoid), [.high])
    }

    func testAvoidIsUnreadableWhenTheOnlyIngredientEntryIsAnAdvisory() {
        let a = evaluate(.avoiding("grapefruit"), .label(ingredients: ["May contain tree nuts"]))
        XCTAssertEqual(a.verdict, .unknown)
        XCTAssertEqual(severities(a, .avoid), [.unreadable])
    }

    func testUnreadableFixtureIsUnknownForAnAvoidList() throws {
        let a = evaluate(.avoiding("grapefruit"), try FoodLabelFixtures.unreadable())
        XCTAssertEqual(a.verdict, .unknown, "the fixture has a product name but no ingredients")
        XCTAssertEqual(a.findings.map(\.restriction), [.avoid])
    }

    func testAvoidWordAbsentFits() {
        XCTAssertEqual(evaluate(.avoiding("grapefruit"), .label(ingredients: ["water", "orange juice"])).verdict, .fits)
    }

    // MARK: - Aggregation

    func testAnyHighWinsOverModerate() {
        var profile = DietaryProfile.lowSodiumOnly
        profile.carbAware = true
        let a = evaluate(profile, .label(sodium: 190, carbs: 60))
        XCTAssertEqual(a.verdict, .doesNotFit)
        XCTAssertEqual(a.findings.map(\.severity), [.high, .moderate], "most severe first")
        XCTAssertEqual(a.findings[0].restriction, .carbs)
    }

    func testModerateWinsOverUnreadable() {
        var profile = DietaryProfile.lowSodiumOnly
        profile.carbAware = true
        let a = evaluate(profile, .label(sodium: 190, carbs: nil))
        XCTAssertEqual(a.verdict, .caution)
        XCTAssertEqual(a.findings.map(\.severity), [.moderate, .unreadable])
    }

    func testUnreadableAloneIsUnknown() {
        var profile = DietaryProfile.lowSodiumOnly
        profile.carbAware = true
        let a = evaluate(profile, .label(sodium: 10, carbs: nil))
        XCTAssertEqual(a.verdict, .unknown)
    }

    func testEverythingEvaluableAndCleanFits() throws {
        let a = evaluate(.lowSodiumPeanutAllergy, try FoodLabelFixtures.beans())
        XCTAssertEqual(a.verdict, .fits)
        XCTAssertTrue(a.findings.isEmpty)
        XCTAssertEqual(a.servingsPerContainer, 3.5)
    }

    func testEmptyProfileIsNoProfile() throws {
        let a = evaluate(DietaryProfile(), try FoodLabelFixtures.soup())
        XCTAssertEqual(a.verdict, .noProfile)
        XCTAssertTrue(a.findings.isEmpty)
    }

    func testNotFoundIsNotALabel() throws {
        let a = evaluate(.lowSodiumPeanutAllergy, try FoodLabelFixtures.notALabel())
        XCTAssertEqual(a.verdict, .notALabel)
    }

    func testSoupFixtureDoesNotFitLowSodiumPeanutProfile() throws {
        let a = evaluate(.lowSodiumPeanutAllergy, try FoodLabelFixtures.soup())
        XCTAssertEqual(a.verdict, .doesNotFit)
        XCTAssertEqual(a.findings.count, 1, "890 mg sodium; no peanuts anywhere on the label")
        XCTAssertEqual(a.findings[0].restriction, .sodium)
        XCTAssertEqual(a.servingsPerContainer, 2.5)
    }

    func testCerealFixtureIsCautionForLowSodiumCarbAware() throws {
        var profile = DietaryProfile.lowSodiumOnly
        profile.carbAware = true
        let a = evaluate(profile, try FoodLabelFixtures.cereal())
        XCTAssertEqual(a.verdict, .caution)
        XCTAssertEqual(a.findings.map(\.restriction), [.sodium, .carbs])
    }

    func testUnreadableFixtureIsUnknown() throws {
        let a = evaluate(.lowSodiumPeanutAllergy, try FoodLabelFixtures.unreadable())
        XCTAssertEqual(a.verdict, .unknown)
        XCTAssertEqual(a.findings.map(\.restriction), [.sodium, .allergy])
        XCTAssertTrue(a.findings.allSatisfy { $0.severity == .unreadable })
    }

    // MARK: - Vocabulary

    func testFindingsNeverUseForbiddenWords() throws {
        var profile = DietaryProfile.lowSodiumPeanutAllergy
        profile.carbAware = true
        profile.lowSaturatedFat = true
        profile.lowPotassium = true
        profile.glutenFree = true
        profile.avoidIngredients = ["grapefruit"]
        for label in [try FoodLabelFixtures.soup(), try FoodLabelFixtures.cereal(), try FoodLabelFixtures.beans(), try FoodLabelFixtures.unreadable()] {
            for finding in evaluate(profile, label).findings {
                let text = finding.spoken.lowercased()
                for word in ["safe", "healthy", "you should", "don't eat"] {
                    XCTAssertFalse(text.contains(word), "\"\(finding.spoken)\" contains \"\(word)\"")
                }
            }
        }
    }
}
