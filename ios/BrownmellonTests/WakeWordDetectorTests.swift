import XCTest
@testable import Brownmellon

/// The wake word is the single point every voice feature passes through — if it
/// misfires the demo looks broken, and if it under-fires the wearer thinks the
/// glasses are ignoring them. These cases are cheap insurance on both.
final class WakeWordDetectorTests: XCTestCase {
    private let detector = WakeWordDetector()

    private func command(_ transcript: String) -> String? {
        detector.detect(in: transcript)?.command
    }

    func testCleanTranscripts() {
        XCTAssertEqual(
            command("Hey Dojo, remind me to take my pills at 8"),
            "remind me to take my pills at 8"
        )
        XCTAssertEqual(command("Hey Dojo what do I have today"), "what do i have today")
        XCTAssertEqual(command("hey dojo scan this"), "scan this")
    }

    /// Recognizers have no prior for "Dojo" and reliably mangle it.
    func testAcceptsCommonMisrecognitions() {
        XCTAssertEqual(command("hey dodo remind me about lunch"), "remind me about lunch")
        XCTAssertEqual(command("hey doe joe what do I have today"), "what do i have today")
        XCTAssertEqual(command("hey dough joe read this to me"), "read this to me")
        XCTAssertEqual(command("hey dojoe check this ad"), "check this ad")
    }

    func testFiresMidSentence() {
        XCTAssertEqual(command("um okay hey dojo call my daughter"), "call my daughter")
    }

    func testDoesNotFireWithoutWakeWord() {
        XCTAssertNil(command("remind me to take my pills"))
        XCTAssertNil(command("the dog ate my homework"))
        XCTAssertNil(command("hey there how are you"))
    }

    /// The wake word alone is a real detection with nothing to act on —
    /// `WakeWordListener` is what declines to dispatch it.
    func testWakeWordAloneYieldsEmptyCommand() {
        XCTAssertEqual(command("hey dojo"), "")
    }

    /// A streaming transcript keeps every command of the segment. The one the
    /// wearer just said is the last one.
    func testDetectLatestPicksTheLastWakeWord() {
        let tokens = WakeWordDetector.tokenize("hey dojo scan this hey dojo read this to me")
        XCTAssertEqual(detector.detect(tokens: tokens)?.command, "scan this hey dojo read this to me")
        XCTAssertEqual(detector.detectLatest(tokens: tokens)?.command, "read this to me")
    }

    // MARK: - Debounce

    /// Streaming recognizers resend the same utterance as it grows. Without the
    /// cooldown this schedules one appointment per partial transcript.
    func testSuppressesStreamingPartials() {
        let listener = WakeWordListener(cooldown: 2.0)
        let start = Date()

        XCTAssertEqual(listener.consume("hey dojo remind", now: start), "remind")
        XCTAssertNil(listener.consume("hey dojo remind me", now: start.addingTimeInterval(0.3)))
        XCTAssertNil(listener.consume("hey dojo remind me at 8", now: start.addingTimeInterval(0.8)))
        XCTAssertEqual(
            listener.consume("hey dojo what do I have today", now: start.addingTimeInterval(3.0)),
            "what do i have today"
        )
    }

    func testListenerIgnoresBareWakeWord() {
        let listener = WakeWordListener(cooldown: 2.0)
        XCTAssertNil(listener.consume("hey dojo", now: Date()))
    }
}
