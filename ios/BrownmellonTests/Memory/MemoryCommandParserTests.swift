import XCTest
@testable import Brownmellon

/// The parser is the memory feature's contract with every other voice
/// feature: it claims exactly the PRD's phrases and nothing else. Inputs here
/// are written the way `WakeWordDetector.normalize` delivers them (lowercase,
/// punctuation → spaces), with a few raw ones to prove the typed path
/// normalizes the same way.
final class MemoryCommandParserTests: XCTestCase {
    private func parse(_ command: String) -> MemoryCommand? {
        MemoryCommandParser.parse(command)
    }

    // MARK: - 9a Save

    func testRememberPrefixIsStrippedAndParkingDetected() {
        XCTAssertEqual(
            parse("remember i parked in section b"),
            .save(text: "i parked in section b", wantsParkingPhoto: false, isParking: true)
        )
    }

    func testEverySavePrefixIsClaimed() {
        let expected = MemoryCommand.save(
            text: "i put my glasses case in the kitchen drawer", wantsParkingPhoto: false, isParking: false
        )
        XCTAssertEqual(parse("remember i put my glasses case in the kitchen drawer"), expected)
        XCTAssertEqual(parse("remember that i put my glasses case in the kitchen drawer"), expected)
        XCTAssertEqual(parse("note that i put my glasses case in the kitchen drawer"), expected)
        XCTAssertEqual(parse("don t forget that i put my glasses case in the kitchen drawer"), expected)
        XCTAssertEqual(parse("dont forget that i put my glasses case in the kitchen drawer"), expected)
        XCTAssertEqual(parse("make a note that i put my glasses case in the kitchen drawer"), expected)
    }

    func testRawApostropheAndCapitalsNormalizeBeforeMatching() {
        // The Simulator "Try it" field sends raw text; the voice path sends
        // normalized text. Both must classify identically.
        XCTAssertEqual(
            parse("Don't forget that Frank is the new neighbor."),
            .save(text: "frank is the new neighbor", wantsParkingPhoto: false, isParking: false)
        )
        XCTAssertEqual(
            parse("Remember I parked in Section B!"),
            .save(text: "i parked in section b", wantsParkingPhoto: false, isParking: true)
        )
    }

    func testEmptyRemainderIsASaveWithNoText() {
        XCTAssertEqual(parse("remember"), .save(text: "", wantsParkingPhoto: false, isParking: false))
        XCTAssertEqual(parse("remember that"), .save(text: "", wantsParkingPhoto: false, isParking: false))
        XCTAssertEqual(parse("note that"), .save(text: "", wantsParkingPhoto: false, isParking: false))
    }

    func testPhotoOnlyParkingPhrases() {
        let photo = MemoryCommand.save(text: "", wantsParkingPhoto: true, isParking: true)
        XCTAssertEqual(parse("remember where i parked"), photo)
        XCTAssertEqual(parse("remember where i m parked"), photo, "normalized \"where I'm parked\"")
        XCTAssertEqual(parse("remember where im parked"), photo)
        XCTAssertEqual(parse("remember my parking spot"), photo)
        XCTAssertEqual(parse("remember that i parked"),
                       .save(text: "i parked", wantsParkingPhoto: false, isParking: true),
                       "content beyond the photo phrases is a text note, not a photo")
    }

    func testNamingTheCarStillMeansPhotographTheSpot() {
        // "Remember where I parked my car" carries no fact to write down — the
        // only useful thing to do is photograph the marker, same as the
        // shorter phrasing.
        let photo = MemoryCommand.save(text: "", wantsParkingPhoto: true, isParking: true)
        for phrase in [
            "remember where i parked my car",
            "remember where i parked the car",
            "remember where my car is parked",
            "remember where i left my car",
            "remember where the car is",
        ] {
            XCTAssertEqual(parse(phrase), photo, phrase)
        }
        XCTAssertEqual(parse("remember where i parked my car in lot c"),
                       .save(text: "where i parked my car in lot c", wantsParkingPhoto: false, isParking: true),
                       "extra words are content again")
    }

    func testPleaseIsStrippedButOtherLeadInsAreNot() {
        XCTAssertEqual(parse("please remember i parked in lot c"),
                       .save(text: "i parked in lot c", wantsParkingPhoto: false, isParking: true))
        XCTAssertEqual(parse("remember i parked in lot c please"),
                       .save(text: "i parked in lot c", wantsParkingPhoto: false, isParking: true),
                       "a trailing please is not part of the note")
        XCTAssertEqual(parse("please forget that"), .forgetLast)
        XCTAssertEqual(parse("forget that please"), .forgetLast)
        XCTAssertEqual(parse("please where did i put my keys"), .recall(question: "where did i put my keys"))
        XCTAssertNil(parse("please"), "a bare please is nothing")
        XCTAssertNil(parse("please remind me to take my pills at 8"), "politeness never turns a reminder into a note")
        XCTAssertEqual(parse("can you remember where i parked"), .recallParking,
                       "'can you' is a question, not a courtesy word — it stays a recall")
        XCTAssertNil(parse("could you remember i parked in lot c"),
                     "only 'please' is stripped; other lead-ins keep the literal contract")
    }

    func testParkingWordVariantsMarkTheNoteAsParking() {
        XCTAssertEqual(parse("remember i parked on level three"),
                       .save(text: "i parked on level three", wantsParkingPhoto: false, isParking: true))
        XCTAssertEqual(parse("remember my parking is in lot c"),
                       .save(text: "my parking is in lot c", wantsParkingPhoto: false, isParking: true))
        XCTAssertEqual(parse("remember the car is in the park and ride"),
                       .save(text: "the car is in the park and ride", wantsParkingPhoto: false, isParking: true))
    }

    func testRememberingIsNotRemember() {
        XCTAssertNil(parse("remembering things is hard"), "prefixes match whole words only")
    }

    // MARK: - 9b Parking recall

    func testEveryParkingRecallPhraseIsClaimed() {
        for phrase in [
            "where did i park",
            "where s my car",          // "where's my car"
            "where is my car",
            "where did i leave the car",
            "hey where did i park the car",
            "do you remember where i parked",
        ] {
            XCTAssertEqual(parse(phrase), .recallParking, phrase)
        }
    }

    func testParkingRecallBeatsGeneralRecallForCarQuestions() {
        XCTAssertEqual(parse("do you remember where i parked"), .recallParking)
        XCTAssertEqual(parse("where is my car"), .recallParking, "not a general 'where is my' question")
    }

    // MARK: - 9b Directions

    func testDirectionsPhrases() {
        XCTAssertEqual(parse("take me to my car"), .directionsToCar)
        XCTAssertEqual(parse("directions to my car"), .directionsToCar)
        XCTAssertEqual(parse("please take me to my car"), .directionsToCar)
    }

    // MARK: - 9b General recall

    func testEveryGeneralRecallPhraseIsClaimedWithTheWholeQuestion() {
        for phrase in [
            "where did i put my glasses case",
            "where s my glasses case",
            "where is my hearing aid",
            "where are my keys",
            "what did i tell you about frank",
            "what did i say about the plumber",
            "do you remember the neighbor s name",
            "what do you remember about frank",
            "what did i ask you to remember",
        ] {
            XCTAssertEqual(parse(phrase), .recall(question: phrase), phrase)
        }
    }

    func testGeneralRecallQuestionIsNormalized() {
        XCTAssertEqual(parse("Where did I put my keys?"), .recall(question: "where did i put my keys"))
    }

    // MARK: - Must NOT claim

    func testRemindIsNeverClaimed() {
        for phrase in [
            "remind me to take my pills at 8",
            "remind me to call my daughter tomorrow at 3",
            "remind me about the dentist",
            "remind me where i parked",   // still Feature 1's word
            "set a reminder for 6 pm",
        ] {
            XCTAssertNil(parse(phrase), phrase)
        }
    }

    func testCalendarPhrasingIsNeverClaimed() {
        for phrase in [
            "where is my next appointment",
            "where s my appointment tomorrow",
            "where is my meeting",
            "where did i put my schedule",
            "what did i tell you about my calendar",
            "do you remember my appointments this week",
        ] {
            XCTAssertNil(parse(phrase), phrase)
        }
    }

    func testOtherFeaturesCommandsAreNeverClaimed() {
        for phrase in [
            "what do i have today",
            "schedule a dentist appointment tomorrow at 2",
            "scan this",
            "read this to me",
            "check this ad",
            "can i eat this",
            "call my daughter",
            "what s the weather",
            "",
        ] {
            XCTAssertNil(parse(phrase), phrase)
        }
    }

    func testWholeWordMatchingAvoidsNearMisses() {
        XCTAssertEqual(parse("where is my cart"), .recall(question: "where is my cart"),
                       "'car' must not match inside 'cart' — this is a general question, not parking")
        XCTAssertNil(parse("wherever my dog goes"), "'where s my' must not match a partial word")
    }

    // MARK: - 9c Forget

    func testForgetParking() {
        XCTAssertEqual(parse("forget my parking spot"), .forgetLastParking)
        XCTAssertEqual(parse("forget where i parked"), .forgetLastParking)
        XCTAssertEqual(parse("forget my car"), .forgetLastParking)
    }

    func testForgetLast() {
        XCTAssertEqual(parse("forget that"), .forgetLast)
        XCTAssertEqual(parse("forget the last thing"), .forgetLast)
    }

    func testForgetEverythingIsTwoSteps() {
        XCTAssertEqual(parse("forget everything"), .forgetAllRequest)
        XCTAssertEqual(parse("yes forget everything"), .forgetAllConfirm)
        XCTAssertEqual(parse("Yes, forget everything."), .forgetAllConfirm, "raw typed form normalizes to the exact confirmation")
        XCTAssertNil(parse("yes"), "a bare yes is not the confirmation")
        XCTAssertNil(parse("yes forget it all"), "only the exact follow-up confirms")
    }

    func testUnrecognizedForgetIsClaimedButNotDestructive() {
        XCTAssertEqual(parse("forget"), .forgetUnrecognized)
        XCTAssertEqual(parse("forget about the dentist"), .forgetUnrecognized)
    }

    func testForgetWinsOverEverythingElse() {
        // "don't forget that …" is a save (checked by whole-word prefix), but
        // anything that *starts* with forget is a forget.
        XCTAssertEqual(parse("forget where my car is"), .forgetLastParking)
        XCTAssertEqual(parse("don t forget that the car is in lot b"),
                       .save(text: "the car is in lot b", wantsParkingPhoto: false, isParking: false))
    }

    /// "Forget it" is how people cancel. It must never delete anything.
    func testForgetItAndNeverMindAreNonDestructive() {
        for phrase in ["forget it", "Forget it.", "forget about it", "never mind", "nevermind", "never mind that"] {
            XCTAssertEqual(parse(phrase), .dismiss, phrase)
        }
        // "cancel …" after a reminder is a calendar request; an "Okay." here
        // would falsely confirm it.
        XCTAssertNil(parse("cancel"))
        XCTAssertNil(parse("cancel that"))
        XCTAssertNil(parse("cancel my appointment"), "calendar phrasing stays with the calendar")
    }

    /// Asking about the car's *keys* is a general recall, not the parking spot.
    func testCarAccessoriesAreNotParkingRecall() {
        XCTAssertEqual(parse("where s my car keys"), .recall(question: "where s my car keys"))
        XCTAssertEqual(parse("Where's my car keys?"), .recall(question: "where s my car keys"))
        XCTAssertEqual(parse("where is my car key"), .recall(question: "where is my car key"))
        XCTAssertEqual(parse("where did i leave my car keys"), .recall(question: "where did i leave my car keys"))
        XCTAssertEqual(parse("where s my car charger"), .recall(question: "where s my car charger"))
        XCTAssertEqual(parse("where s my car"), .recallParking, "…but the car itself is still parking")
    }
}
