import XCTest
@testable import Brownmellon

/// Every non-calendar feature is reached through this classifier, on-device,
/// with no backend. Under-matching means "Hey Dojo, scan this" goes to the
/// model and costs quota; over-matching means "check my calendar" takes a
/// photo. Both are demo-killers.
final class VoiceCommandClassifierTests: XCTestCase {
    private let classifier = VoiceCommandClassifier()

    private func classify(_ command: String) -> LocalVoiceCommand? {
        classifier.classify(command)
    }

    // MARK: - Feature 3: scan

    func testScanCard() {
        XCTAssertEqual(classify("scan this"), .scanCard)
        XCTAssertEqual(classify("Scan the card"), .scanCard)
        XCTAssertEqual(classify("scan my appointment card"), .scanCard)
        XCTAssertEqual(classify("add this card to my calendar"), .scanCard)
        XCTAssertEqual(classify("check this card"), .scanCard)
    }

    // MARK: - Feature 4: read

    func testReadText() {
        XCTAssertEqual(classify("read this to me"), .readText)
        XCTAssertEqual(classify("read this"), .readText)
        XCTAssertEqual(classify("read it"), .readText)
        XCTAssertEqual(classify("what does this say"), .readText)
        XCTAssertEqual(classify("what does it say?"), .readText)
        XCTAssertEqual(classify("read this letter out loud"), .readText)
    }

    func testReadingTheCalendarIsNotACameraCommand() {
        XCTAssertNil(classify("read me my schedule"))
        XCTAssertNil(classify("read my calendar for today"))
    }

    // MARK: - Feature 5: check ad

    func testCheckAd() {
        XCTAssertEqual(classify("check this ad"), .checkAd)
        // Speech recognition's favorite spellings of "ad".
        XCTAssertEqual(classify("check this add"), .checkAd)
        XCTAssertEqual(classify("check this at"), .checkAd)
        XCTAssertEqual(classify("check the advertisement"), .checkAd)
        XCTAssertEqual(classify("is this a scam"), .checkAd)
        XCTAssertEqual(classify("is this legit"), .checkAd)
        XCTAssertEqual(classify("is this real"), .checkAd)
        XCTAssertEqual(classify("does this look fake"), .checkAd)
    }

    func testCheckingTheCalendarIsNotAnAdCheck() {
        XCTAssertNil(classify("check my calendar"))
        XCTAssertNil(classify("check what I have tomorrow"))
    }

    // MARK: - Feature 6: calls

    func testEmergency() {
        XCTAssertEqual(classify("call 911"), .callEmergency)
        XCTAssertEqual(classify("call nine one one"), .callEmergency)
        XCTAssertEqual(classify("call nine-one-one"), .callEmergency)
        XCTAssertEqual(classify("call nine eleven"), .callEmergency)
        XCTAssertEqual(classify("call emergency services"), .callEmergency)
        XCTAssertEqual(classify("call the police"), .callEmergency)
        XCTAssertEqual(classify("call an ambulance"), .callEmergency)
        XCTAssertEqual(classify("emergency"), .callEmergency)
        XCTAssertEqual(classify("this is an emergency"), .callEmergency)
    }

    func testCallContact() {
        XCTAssertEqual(classify("call my daughter"), .callContact("daughter"))
        XCTAssertEqual(classify("call daughter"), .callContact("daughter"))
        XCTAssertEqual(classify("phone my son please"), .callContact("son"))
        XCTAssertEqual(classify("please call my son"), .callContact("son"))
        XCTAssertEqual(classify("call up my neighbor now"), .callContact("neighbor"))
        XCTAssertEqual(classify("call my son in law"), .callContact("son in law"))
    }

    func testRemindMeToCallIsScheduling() {
        // "call" in the middle of a reminder is not a call.
        XCTAssertNil(classify("remind me to call the dentist tomorrow"))
        XCTAssertNil(classify("remind me to call my daughter at 5"))
    }

    // MARK: - Confirmations by wake word

    func testBareAnswersAfterWakeWord() {
        XCTAssertEqual(classify("yes"), .confirmYes)
        XCTAssertEqual(classify("yes please"), .confirmYes)
        XCTAssertEqual(classify("okay"), .confirmYes)
        XCTAssertEqual(classify("no"), .confirmNo)
        XCTAssertEqual(classify("never mind"), .confirmNo)
        XCTAssertEqual(classify("cancel"), .confirmNo)
    }

    func testLongSentencesStartingWithNoAreNotAnswers() {
        XCTAssertNil(classify("no wait remind me at nine instead"))
    }

    // MARK: - Everything else goes to the backend

    func testSchedulingGoesToBackend() {
        XCTAssertNil(classify("remind me to take my pills at 8"))
        XCTAssertNil(classify("what do I have today"))
        XCTAssertNil(classify("schedule lunch with Maria on Friday at noon"))
        XCTAssertNil(classify("what's the weather"))
    }
}

final class ConfirmationDetectorTests: XCTestCase {
    private let detector = ConfirmationDetector()

    func testYes() {
        XCTAssertEqual(detector.detect(in: "yes"), true)
        XCTAssertEqual(detector.detect(in: "Yes, please."), true)
        XCTAssertEqual(detector.detect(in: "um yeah"), true)
        XCTAssertEqual(detector.detect(in: "that's right"), true)
    }

    func testNo() {
        XCTAssertEqual(detector.detect(in: "no"), false)
        XCTAssertEqual(detector.detect(in: "no thanks"), false)
        XCTAssertEqual(detector.detect(in: "never mind"), false)
        // A negative anywhere in the window beats a positive.
        XCTAssertEqual(detector.detect(in: "no that's not right"), false)
        XCTAssertEqual(detector.detect(in: "yes no wait"), false)
    }

    /// The assistant's own question leaks into the mic. None of it may read
    /// as an answer, or the app confirms its own calendar write.
    func testOurOwnQuestionIsNotAnAnswer() {
        XCTAssertNil(detector.detect(in: "I found Doctor Reyes, Tuesday at 2 PM. Should I add it to your calendar?"))
        XCTAssertNil(detector.detect(in: "should i add it to your calendar"))
        XCTAssertNil(detector.detect(in: "add it to your calendar"))
        XCTAssertNil(detector.detect(in: "your calendar"))
    }

    func testOnlyTheOpeningWordsCount() {
        XCTAssertNil(detector.detect(in: "I think the answer is yes"))
    }
}
