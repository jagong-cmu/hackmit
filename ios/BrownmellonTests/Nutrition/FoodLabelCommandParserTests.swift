import XCTest
@testable import Brownmellon

/// The claimed-phrase contract (PRD-food-label § 10b): every listed phrase
/// routes to the right mode, and the phrases other features own are never
/// claimed. Commands arrive normalized by `WakeWordDetector.normalize`, so the
/// tests pass them through the same function.
final class FoodLabelCommandParserTests: XCTestCase {
    private func parse(_ text: String) -> FoodLabelCommand? {
        FoodLabelCommandParser.parse(WakeWordDetector.normalize(text))
    }

    // MARK: - Read mode

    func testReadModePhrases() {
        for phrase in ["read this label", "read the label", "read this package", "what's in this", "whats in this"] {
            XCTAssertEqual(parse(phrase), .read(.headline), phrase)
        }
        XCTAssertEqual(parse("read the ingredients"), .read(.ingredients))
        XCTAssertEqual(parse("read the nutrition"), .read(.nutrition))
        XCTAssertEqual(parse("read everything on this"), .read(.everything))
        XCTAssertEqual(parse("read everything"), .read(.everything))
    }

    // MARK: - Check mode

    func testCheckModePhrases() {
        for phrase in [
            "can i eat this", "can i have this", "is this okay for me", "is this ok for me",
            "is this good for me", "check this food", "is this safe for me to eat", "does this fit my diet",
        ] {
            XCTAssertEqual(parse(phrase), .check, phrase)
        }
    }

    func testPunctuationAndCaseDoNotMatter() {
        XCTAssertEqual(parse("Can I eat this?"), .check)
        XCTAssertEqual(parse("What's in this?"), .read(.headline))
    }

    // MARK: - Question mode

    func testQuestionPhrases() {
        XCTAssertEqual(parse("how much sodium"), .question(.sodium))
        XCTAssertEqual(parse("how much salt"), .question(.sodium))
        XCTAssertEqual(parse("how much sugar"), .question(.sugar))
        XCTAssertEqual(parse("how many carbs"), .question(.carbs))
        XCTAssertEqual(parse("how much fat"), .question(.fat))
        XCTAssertEqual(parse("when does this expire"), .question(.expiration))
        XCTAssertEqual(parse("how do i cook this"), .question(.preparation))
        XCTAssertEqual(parse("how do i make this"), .question(.preparation))
        XCTAssertEqual(parse("what else"), .question(.whatElse))
    }

    func testQuestionPhrasesAcceptATrailingClause() {
        XCTAssertEqual(parse("how much sodium is in this"), .question(.sodium))
        XCTAssertEqual(parse("how many carbs does this have"), .question(.carbs))
    }

    func testContainsQuestions() {
        XCTAssertEqual(parse("does this have peanuts"), .question(.contains("peanuts")))
        XCTAssertEqual(parse("does this have any milk in it"), .question(.contains("milk")))
        XCTAssertEqual(parse("is there grapefruit in this"), .question(.contains("grapefruit")))
        XCTAssertEqual(parse("is there any soy in this"), .question(.contains("soy")))
        XCTAssertEqual(parse("does this contain tree nuts"), .question(.contains("tree nuts")))
    }

    // MARK: - Not claimed

    func testDoesNotClaimOtherFeaturesPhrases() {
        for phrase in [
            "read this to me", "read this", "read this letter to me",
            "check this ad", "scan this",
            "remind me to take my pills at 8", "what do i have today", "schedule lunch tomorrow at noon",
            "is there anything on my calendar today", "is there a meeting today",
            "remember where i parked", "where did i park",
            "does this have", "how much", "read",
            "what else do i have today", "what else is on my calendar",
            // Starts like ours, but the tail says otherwise.
            "can i have this read to me", "how do i make this appointment", "can i eat this before my meeting",
        ] {
            XCTAssertNil(parse(phrase), "must not claim \"\(phrase)\"")
        }
    }

    func testPolitenessIsStrippedBeforeMatching() {
        XCTAssertEqual(parse("read this label to me"), .read(.headline), "a polite tail on a food command stays food")
        XCTAssertEqual(parse("read the ingredients to me"), .read(.ingredients))
        XCTAssertEqual(parse("please read the label"), .read(.headline))
        XCTAssertEqual(parse("can you read this label"), .read(.headline))
        XCTAssertEqual(parse("could you please read the ingredients"), .read(.ingredients))
        XCTAssertEqual(parse("Can I eat this, please?"), .check)
        XCTAssertEqual(parse("would you check this food"), .check)
        XCTAssertNil(parse("please"), "courtesy alone is not a command")
    }

    func testWhatElseIsExactOnly() {
        XCTAssertEqual(parse("what else"), .question(.whatElse))
        XCTAssertEqual(parse("What else?"), .question(.whatElse))
        XCTAssertNil(parse("what else do i have today"), "the calendar's, not ours")
    }

    func testEmptyCommandIsNotClaimed() {
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("   "))
    }

    func testEveryClaimedPhraseParses() {
        for phrase in FoodLabelCommandParser.claimedPhrases {
            XCTAssertNotNil(parse(phrase), phrase)
        }
    }

    func testClaimedListExcludesOtherFeaturesContract() {
        let forbidden = ["read this to me", "read this", "check this ad", "scan this"].map(WakeWordDetector.normalize)
        for phrase in FoodLabelCommandParser.claimedPhrases {
            XCTAssertFalse(forbidden.contains(phrase), phrase)
        }
    }
}
