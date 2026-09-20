import XCTest
@testable import Brownmellon

/// The spoken scripts are product copy (PRD-food-label § 10c/10d): each
/// verdict against a fixed fixture, fractions in words, at most two findings,
/// servings mentioned at 1.5 and up, and none of the forbidden vocabulary.
final class FoodLabelSpeechTests: XCTestCase {
    private func check(_ profile: DietaryProfile, _ label: FoodLabelResult) -> String {
        let assessment = DietaryFitEvaluator.evaluate(profile, label)
        return FoodLabelSpeech.checkScript(assessment, label: label, profile: profile)
    }

    // MARK: - Numbers in words

    func testQuantityRoundsAndPluralizes() {
        XCTAssertEqual(FoodLabelSpeech.quantity(890, .milligrams, of: "sodium"), "890 milligrams of sodium")
        XCTAssertEqual(FoodLabelSpeech.quantity(1, .grams, of: "sugar"), "1 gram of sugar")
        XCTAssertEqual(FoodLabelSpeech.quantity(2.4, .grams, of: "fat"), "2 grams of fat")
        XCTAssertEqual(FoodLabelSpeech.quantity(0.4, .grams, of: "trans fat"), "less than 1 gram of trans fat")
        XCTAssertEqual(FoodLabelSpeech.quantity(0, .grams, of: "fat"), "0 grams of fat")
        XCTAssertEqual(FoodLabelSpeech.quantity(60, .calories), "60 calories")
        XCTAssertEqual(FoodLabelSpeech.quantity(1, .calories), "1 calorie")
    }

    func testFractionsAreWordsNeverPercentages() {
        XCTAssertEqual(FoodLabelSpeech.fraction(890.0 / 1500.0, of: "your daily limit"), "more than half of your daily limit")
        XCTAssertEqual(FoodLabelSpeech.fraction(190.0 / 1500.0, of: "your daily limit"), "about an eighth of your daily limit")
        XCTAssertEqual(FoodLabelSpeech.fraction(22.0 / 45.0, of: "your meal budget"), "about half your meal budget")
        XCTAssertEqual(FoodLabelSpeech.fraction(0.49, of: "your daily limit"), "about half of your daily limit")
        XCTAssertEqual(FoodLabelSpeech.fraction(0.33, of: "your daily limit"), "about a third of your daily limit")
        XCTAssertEqual(FoodLabelSpeech.fraction(0.25, of: "your daily limit"), "about a quarter of your daily limit")
        XCTAssertEqual(FoodLabelSpeech.fraction(0.20, of: "your daily limit"), "about a fifth of your daily limit")
        XCTAssertEqual(FoodLabelSpeech.fraction(0.10, of: "your daily limit"), "about a tenth of your daily limit")
        XCTAssertEqual(FoodLabelSpeech.fraction(0.75, of: "your daily limit"), "about three quarters of your daily limit")
        XCTAssertEqual(FoodLabelSpeech.fraction(1.0, of: "your daily limit"), "about your whole daily limit")
        XCTAssertEqual(FoodLabelSpeech.fraction(1.5, of: "your daily limit"), "more than your whole daily limit")
        XCTAssertEqual(FoodLabelSpeech.fraction(0.02, of: "your daily limit"), "a small part of your daily limit")
        for ratio in stride(from: 0.0, through: 2.0, by: 0.01) {
            XCTAssertFalse(FoodLabelSpeech.fraction(ratio, of: "your daily limit").contains("%"))
        }
    }

    func testServingsInWords() {
        XCTAssertEqual(FoodLabelSpeech.spokenServings(2.5), "two and a half")
        XCTAssertEqual(FoodLabelSpeech.spokenServings(2.3), "two and a half")
        XCTAssertEqual(FoodLabelSpeech.spokenServings(2.2), "two")
        XCTAssertEqual(FoodLabelSpeech.spokenServings(1.5), "one and a half")
        XCTAssertEqual(FoodLabelSpeech.spokenServings(12), "twelve")
        XCTAssertEqual(FoodLabelSpeech.spokenServings(24), "24")
    }

    func testServingsSentenceOnlyAtOneAndAHalfOrMore() {
        XCTAssertNil(FoodLabelSpeech.servingsSentence(nil))
        XCTAssertNil(FoodLabelSpeech.servingsSentence(1))
        XCTAssertNil(FoodLabelSpeech.servingsSentence(1.4))
        XCTAssertEqual(FoodLabelSpeech.servingsSentence(1.5), "And the package is about one and a half servings.")
        XCTAssertEqual(FoodLabelSpeech.servingsSentence(2.5), "And the package is about two and a half servings.")
    }

    func testServingSizeDropsGramsAndSpeaksFractions() {
        XCTAssertEqual(FoodLabelSpeech.spokenServingSize("1 cup (245g)"), "1 cup")
        XCTAssertEqual(FoodLabelSpeech.spokenServingSize("2/3 cup (55g)"), "two thirds cup")
        XCTAssertEqual(FoodLabelSpeech.spokenServingSize("1 1/2 cups (39g)"), "1 and a half cups")
        XCTAssertEqual(FoodLabelSpeech.spokenServingSize("1/4 cup dry (45g)"), "one quarter cup dry")
        XCTAssertEqual(FoodLabelSpeech.spokenServingSize("(30g)"), "(30g)", "never empty")
    }

    func testJoinedList() {
        XCTAssertEqual(FoodLabelSpeech.joinedList(["wheat"]), "wheat")
        XCTAssertEqual(FoodLabelSpeech.joinedList(["wheat", "soy"]), "wheat and soy")
        XCTAssertEqual(FoodLabelSpeech.joinedList(["wheat", "chicken", "soy"]), "wheat, chicken, and soy")
    }

    // MARK: - Check mode scripts

    func testDoesNotFitScript() throws {
        var profile = DietaryProfile.lowSodiumOnly
        profile.avoidIngredients = ["wheat"]
        XCTAssertEqual(
            check(profile, try FoodLabelFixtures.soup()),
            "This is Campbell's Chicken Noodle Soup. One serving has 890 milligrams of sodium — that's more than half of your daily limit, so it doesn't fit your low-sodium diet. It also contains wheat, which you avoid. And the package is about two and a half servings."
        )
    }

    func testCautionScript() throws {
        var profile = DietaryProfile.lowSodiumOnly
        profile.carbAware = true
        XCTAssertEqual(
            check(profile, try FoodLabelFixtures.cereal()),
            "This is Cheerios. One serving has 190 milligrams of sodium, about an eighth of your daily limit, and 23 grams of carbohydrates, about half your meal budget. It's a moderate fit for your diet. And the package is about twelve servings."
        )
    }

    func testFitsScript() throws {
        XCTAssertEqual(
            check(.lowSodiumPeanutAllergy, try FoodLabelFixtures.beans()),
            "This is Del Monte No Salt Added Green Beans. It fits your diet — 10 milligrams of sodium per serving, and none of the ingredients you avoid. And the package is about three and a half servings."
        )
    }

    func testFitsScriptWithOnlyIngredientRules() throws {
        XCTAssertEqual(
            check(.allergy(.peanuts), try FoodLabelFixtures.beans()),
            "This is Del Monte No Salt Added Green Beans. It fits your diet — none of the ingredients you avoid. And the package is about three and a half servings."
        )
    }

    func testUnknownScript() throws {
        XCTAssertEqual(
            check(.lowSodiumOnly, try FoodLabelFixtures.unreadable()),
            "I could read most of this label, but the sodium wasn't legible. Try a closer photo of the Nutrition Facts panel. Hold it about a foot from your face."
        )
        XCTAssertEqual(
            check(.lowSodiumPeanutAllergy, try FoodLabelFixtures.unreadable()),
            "I could read most of this label, but the sodium and the ingredients weren't legible. Try a closer photo of the Nutrition Facts panel. Hold it about a foot from your face."
        )
    }

    func testNoProfileScriptReadsTheLabelInstead() throws {
        XCTAssertEqual(
            check(DietaryProfile(), try FoodLabelFixtures.soup()),
            "No diet has been set up yet, so I can't check this for you — your helper can add one in Setup. Here's the label: Per serving: 60 calories, 890 milligrams of sodium, 8 grams of carbohydrates with 1 gram of sugar, 2 grams of fat, 3 grams of protein."
        )
    }

    func testNotALabelScript() throws {
        XCTAssertEqual(
            check(.lowSodiumPeanutAllergy, try FoodLabelFixtures.notALabel()),
            "I don't see a nutrition label. Hold the Nutrition Facts panel or the ingredients list in front of you, about a foot from your face."
        )
    }

    func testAtMostTwoFindingsAreSpokenAndTheRestAreOffered() throws {
        var profile = DietaryProfile.lowSodiumOnly
        profile.glutenFree = true
        profile.allergens = [.eggs, .wheat, .soybeans]
        let soup = try FoodLabelFixtures.soup()
        let assessment = DietaryFitEvaluator.evaluate(profile, soup)
        XCTAssertGreaterThan(assessment.findings.count, 3)

        let script = FoodLabelSpeech.checkScript(assessment, label: soup, profile: profile)
        XCTAssertEqual(script.components(separatedBy: "It also").count - 1, 1, "one lead finding plus one 'also'")
        XCTAssertTrue(script.contains("more things to watch — say 'what else' to hear them."), script)

        let rest = FoodLabelSpeech.whatElseScript(assessment)
        XCTAssertTrue(rest.hasPrefix("Also: "))
        XCTAssertEqual(rest.components(separatedBy: ". ").count, assessment.findings.count - 2)
    }

    func testWhatElseWithNothingMore() throws {
        let assessment = DietaryFitEvaluator.evaluate(.lowSodiumPeanutAllergy, try FoodLabelFixtures.soup())
        XCTAssertEqual(FoodLabelSpeech.whatElseScript(assessment), "Nothing else to watch on this label.")
        XCTAssertEqual(FoodLabelSpeech.whatElseScript(nil), "I haven't checked a label yet. Say 'can I eat this' while holding the package up.")
    }

    func testInfoFindingIsStillSpokenOnFits() {
        let label = FoodLabelResult.label(name: "Rice Cakes", servings: 1, sodium: 10, potassium: nil, ingredients: ["rice"])
        XCTAssertEqual(
            check(.lowPotassiumOnly, label),
            "This is Rice Cakes. It fits your diet. The label doesn't list potassium."
        )
    }

    // MARK: - Read mode scripts

    func testReadHeadlineOrder() throws {
        let soup = try FoodLabelFixtures.soup()
        XCTAssertEqual(
            FoodLabelSpeech.readHeadline(soup),
            "This is Campbell's Chicken Noodle Soup. One serving is 1 cup, and the package has about two and a half servings. "
                + "Per serving: 60 calories, 890 milligrams of sodium, 8 grams of carbohydrates with 1 gram of sugar, 2 grams of fat, 3 grams of protein. "
                + "It contains wheat, egg, and soy. "
                + "Say 'read the ingredients' for the full list, or 'read everything' for the whole label."
        )
        XCTAssertFalse(FoodLabelSpeech.readHeadline(soup).contains(soup.fullText), "never fullText first")
    }

    func testContainsSentenceFallsBackToFirstFiveIngredients() throws {
        var soup = try FoodLabelFixtures.soup()
        soup.containsStatement = nil
        XCTAssertEqual(
            FoodLabelSpeech.containsSentence(soup),
            "It contains Chicken stock, Enriched egg noodles (wheat flour, egg whites, eggs, niacin, ferrous sulfate, thiamine mononitrate, riboflavin, folic acid), Chicken meat, Salt, Carrots, and more."
        )
        XCTAssertEqual(FoodLabelSpeech.containsSentence(try FoodLabelFixtures.beans()), "It contains Green beans and Water.")
        XCTAssertNil(FoodLabelSpeech.containsSentence(try FoodLabelFixtures.unreadable()))
    }

    func testIngredientsScriptInAtMostTwoChunks() throws {
        let long = FoodLabelSpeech.ingredientsScript(try FoodLabelFixtures.soup())
        XCTAssertTrue(long.hasPrefix("The ingredients are Chicken stock, "))
        XCTAssertEqual(long.components(separatedBy: " … and ").count, 2)
        XCTAssertTrue(long.hasSuffix("Beta carotene, Water."))

        XCTAssertEqual(FoodLabelSpeech.ingredientsScript(try FoodLabelFixtures.beans()), "The ingredients are Green beans and Water.")
        XCTAssertEqual(
            FoodLabelSpeech.ingredientsScript(try FoodLabelFixtures.unreadable()),
            "I couldn't read the ingredients list on this label. Try a closer photo of the ingredients."
        )
    }

    func testEverythingExpirationAndPreparation() throws {
        let soup = try FoodLabelFixtures.soup()
        XCTAssertEqual(FoodLabelSpeech.everythingScript(soup), soup.fullText)
        XCTAssertEqual(FoodLabelSpeech.expirationScript(soup), "The label says: Best by MAR 2027.")
        XCTAssertEqual(FoodLabelSpeech.expirationScript(try FoodLabelFixtures.beans()), "I couldn't find a date on this side of the package.")
        XCTAssertTrue(FoodLabelSpeech.preparationScript(soup).hasPrefix("The label says: Mix soup + 1 can water."))
        XCTAssertEqual(FoodLabelSpeech.preparationScript(try FoodLabelFixtures.cereal()), "I couldn't find cooking instructions on this side of the package.")
    }

    // MARK: - Question mode

    func testQuestionsAnswerFromNutrientsWithComparisonWhenActive() throws {
        let soup = try FoodLabelFixtures.soup()
        XCTAssertEqual(
            FoodLabelSpeech.questionScript(.sodium, label: soup, profile: .lowSodiumOnly),
            "890 milligrams of sodium per serving — that's more than half of your daily limit."
        )
        XCTAssertEqual(
            FoodLabelSpeech.questionScript(.sodium, label: soup, profile: DietaryProfile()),
            "890 milligrams of sodium per serving."
        )
        XCTAssertEqual(
            FoodLabelSpeech.questionScript(.sodium, label: try FoodLabelFixtures.unreadable(), profile: .lowSodiumOnly),
            "I couldn't read the sodium on this label. Try a closer photo of the Nutrition Facts panel."
        )

        let cereal = try FoodLabelFixtures.cereal()
        XCTAssertEqual(
            FoodLabelSpeech.questionScript(.carbs, label: cereal, profile: .carbAwareOnly),
            "23 grams of carbohydrates per serving — that's about half your meal budget."
        )
        XCTAssertEqual(
            FoodLabelSpeech.questionScript(.sugar, label: cereal, profile: .carbAwareOnly),
            "2 grams of sugar per serving, 2 of them added."
        )
        XCTAssertEqual(
            FoodLabelSpeech.questionScript(.fat, label: soup, profile: .lowSaturatedFatOnly),
            "2 grams of fat per serving, 1 of them saturated — that's a small part of your daily limit for saturated fat."
        )
    }

    func testContainsQuestions() throws {
        let soup = try FoodLabelFixtures.soup()
        XCTAssertEqual(
            FoodLabelSpeech.questionScript(.contains("peanuts"), label: soup, profile: .lowSodiumPeanutAllergy),
            "I don't see peanuts in the ingredients."
        )
        XCTAssertEqual(
            FoodLabelSpeech.questionScript(.contains("egg"), label: soup, profile: .allergy(.eggs)),
            "Yes — it contains eggs, and you're allergic to eggs."
        )
        XCTAssertEqual(
            FoodLabelSpeech.questionScript(.contains("wheat"), label: soup, profile: .avoiding("wheat")),
            "Yes — it contains wheat, which you avoid."
        )
        XCTAssertEqual(
            FoodLabelSpeech.questionScript(.contains("msg"), label: soup, profile: DietaryProfile()),
            "I don't see msg in the ingredients."
        )
        XCTAssertEqual(
            FoodLabelSpeech.questionScript(.contains("glutamate"), label: soup, profile: DietaryProfile()),
            "Yes — it contains Monosodium glutamate."
        )
        XCTAssertEqual(
            FoodLabelSpeech.questionScript(.contains("peanuts"), label: try FoodLabelFixtures.unreadable(), profile: DietaryProfile()),
            "I couldn't read the ingredients on this label, so I can't tell."
        )
        let mayContain = FoodLabelResult.label(ingredients: ["sugar"], mayContain: "May contain peanuts")
        XCTAssertEqual(
            FoodLabelSpeech.questionScript(.contains("peanuts"), label: mayContain, profile: .lowSodiumPeanutAllergy),
            "The label says it may contain peanuts — and you're allergic to peanuts."
        )
    }

    // MARK: - Vocabulary

    func testScriptsNeverUseForbiddenWords() throws {
        var everything = DietaryProfile.lowSodiumPeanutAllergy
        everything.carbAware = true
        everything.lowSaturatedFat = true
        everything.lowPotassium = true
        everything.glutenFree = true
        everything.avoidIngredients = ["grapefruit", "wheat"]
        let profiles: [DietaryProfile] = [DietaryProfile(), .lowSodiumPeanutAllergy, everything]
        let labels = [
            try FoodLabelFixtures.soup(), try FoodLabelFixtures.cereal(), try FoodLabelFixtures.beans(),
            try FoodLabelFixtures.unreadable(), try FoodLabelFixtures.notALabel(),
        ]
        var scripts: [String] = [FoodLabelSpeech.notALabelScript, FoodLabelSpeech.offer]
        for profile in profiles {
            for label in labels {
                scripts.append(check(profile, label))
                scripts.append(FoodLabelSpeech.readHeadline(label))
                scripts.append(FoodLabelSpeech.ingredientsScript(label))
                for kind: FoodLabelCommand.QuestionKind in [.sodium, .sugar, .carbs, .fat, .contains("peanuts"), .expiration, .preparation] {
                    scripts.append(FoodLabelSpeech.questionScript(kind, label: label, profile: profile))
                }
            }
        }
        for script in scripts {
            let text = script.lowercased()
            for word in ["safe", "healthy", "you should", "don't eat", "%"] {
                XCTAssertFalse(text.contains(word), "\"\(script)\" contains \"\(word)\"")
            }
        }
    }
}
