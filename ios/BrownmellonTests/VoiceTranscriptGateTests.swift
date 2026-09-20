import XCTest
@testable import Brownmellon

/// The gate sits between the streaming recognizer and every feature. These
/// replay the transcript sequences a real `SFSpeechRecognizer` produces —
/// growing partials, one accumulating segment, our own speech echoing back —
/// and check each spoken command becomes exactly one action.
@MainActor
final class VoiceTranscriptGateTests: XCTestCase {
    private var gate: VoiceTranscriptGate!
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        gate = VoiceTranscriptGate(settleDelay: 1.0, confirmationTimeout: 45)
    }

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - Settling

    /// The recognizer sends "hey dojo remind", then "…remind me", then the
    /// whole thing. Only the whole thing may reach the backend.
    func testCommandIsReleasedOnlyAfterTranscriptStopsChanging() {
        XCTAssertNil(gate.consume("hey dojo remind", now: at(0)))
        XCTAssertNil(gate.consume("hey dojo remind me to take", now: at(0.4)))
        XCTAssertNil(gate.consume("hey dojo remind me to take my pills at 8", now: at(0.8)))
        XCTAssertTrue(gate.hasPendingCommand)

        // Not quiet long enough yet.
        XCTAssertNil(gate.settle(now: at(1.5)))
        XCTAssertEqual(gate.settle(now: at(1.9)), .command("remind me to take my pills at 8"))
        XCTAssertFalse(gate.hasPendingCommand)
        XCTAssertNil(gate.settle(now: at(3)))
    }

    /// Identical re-sends of the same partial don't restart the clock.
    func testRepeatedIdenticalPartialDoesNotDelaySettling() {
        XCTAssertNil(gate.consume("hey dojo scan this", now: at(0)))
        XCTAssertNil(gate.consume("hey dojo scan this", now: at(0.5)))
        XCTAssertNil(gate.consume("hey dojo scan this", now: at(0.9)))
        XCTAssertEqual(gate.settle(now: at(1.0)), .command("scan this"))
    }

    func testWakeWordAloneIsNotACommand() {
        XCTAssertNil(gate.consume("hey dojo", now: at(0)))
        XCTAssertFalse(gate.hasPendingCommand)
        XCTAssertNil(gate.settle(now: at(5)))
    }

    func testNoWakeWordNoCommand() {
        XCTAssertNil(gate.consume("remind me to take my pills", now: at(0)))
        XCTAssertFalse(gate.hasPendingCommand)
    }

    // MARK: - One segment, many commands

    /// After acting on a command, the same words stay in the transcript for
    /// the rest of the segment. They must not fire again.
    func testActedCommandDoesNotRefireFromLaterPartials() {
        _ = gate.consume("hey dojo scan this", now: at(0))
        XCTAssertEqual(gate.settle(now: at(1.0)), .command("scan this"))

        // Our reply leaks into the mic and the transcript keeps growing.
        XCTAssertNil(gate.consume("hey dojo scan this I found doctor", now: at(3)))
        XCTAssertNil(gate.consume("hey dojo scan this I found doctor Reyes Tuesday", now: at(3.5)))
        XCTAssertFalse(gate.hasPendingCommand)
        XCTAssertNil(gate.settle(now: at(10)))
    }

    /// A second "hey dojo" later in the same segment is a second command.
    func testSecondCommandInSameSegment() {
        _ = gate.consume("hey dojo scan this", now: at(0))
        XCTAssertEqual(gate.settle(now: at(1.0)), .command("scan this"))

        XCTAssertNil(gate.consume("hey dojo scan this hey dojo read", now: at(8)))
        XCTAssertNil(gate.consume("hey dojo scan this hey dojo read this to me", now: at(8.4)))
        XCTAssertEqual(gate.settle(now: at(9.4)), .command("read this to me"))
    }

    /// The very same command twice in a row is two commands (two cards).
    func testIdenticalCommandTwiceIsTwoCommands() {
        _ = gate.consume("hey dojo scan this", now: at(0))
        XCTAssertEqual(gate.settle(now: at(1.0)), .command("scan this"))

        _ = gate.consume("hey dojo scan this hey dojo scan this", now: at(12))
        XCTAssertEqual(gate.settle(now: at(13)), .command("scan this"))
    }

    /// The recognizer revised "doe joe" → "dojo" (one token fewer) before the
    /// next command arrived. The new command still has to be found whole.
    func testSurvivesRecognizerRevisingEarlierWords() {
        _ = gate.consume("hey doe joe scan this", now: at(0))
        XCTAssertEqual(gate.settle(now: at(1.0)), .command("scan this"))

        _ = gate.consume("hey dojo scan this hey dojo read this", now: at(8))
        XCTAssertEqual(gate.settle(now: at(9)), .command("read this"))
    }

    /// An empty transcript = the recognizer restarted; the next transcript
    /// starts from scratch and the same words are a new command.
    func testSegmentBoundaryResetsHistory() {
        _ = gate.consume("hey dojo scan this", now: at(0))
        XCTAssertEqual(gate.settle(now: at(1.0)), .command("scan this"))

        XCTAssertNil(gate.consume("", now: at(60)))
        _ = gate.consume("hey dojo scan this", now: at(61))
        XCTAssertEqual(gate.settle(now: at(62)), .command("scan this"))
    }

    /// The segment can end while a command is still settling — the command
    /// is still delivered.
    func testCandidateSurvivesSegmentBoundary() {
        _ = gate.consume("hey dojo read this to me", now: at(0))
        XCTAssertNil(gate.consume("", now: at(0.3)))
        XCTAssertEqual(gate.settle(now: at(1.0)), .command("read this to me"))
    }

    // MARK: - Confirmations

    func testBareYesWhileAwaitingConfirmation() {
        _ = gate.consume("hey dojo scan this", now: at(0))
        XCTAssertEqual(gate.settle(now: at(1.0)), .command("scan this"))

        // Feature spoke its question; the echo is in the transcript by the
        // time it asks us to listen for the answer.
        _ = gate.consume("hey dojo scan this I found doctor Reyes should I add it to your calendar", now: at(6))
        gate.awaitConfirmation(now: at(6.5))
        XCTAssertTrue(gate.isAwaitingConfirmation)

        XCTAssertEqual(
            gate.consume("hey dojo scan this I found doctor Reyes should I add it to your calendar yes", now: at(8)),
            .confirmation(true)
        )
        XCTAssertFalse(gate.isAwaitingConfirmation)
    }

    func testBareNoWhileAwaitingConfirmation() {
        _ = gate.consume("hey dojo scan this", now: at(0))
        _ = gate.settle(now: at(1.0))
        _ = gate.consume("hey dojo scan this should I add it to your calendar", now: at(6))
        gate.awaitConfirmation(now: at(6.5))

        XCTAssertEqual(
            gate.consume("hey dojo scan this should I add it to your calendar no thanks", now: at(8)),
            .confirmation(false)
        )
    }

    /// A late-arriving tail of our own question must not answer it.
    func testEchoOfOurQuestionIsNotAnAnswer() {
        _ = gate.consume("hey dojo scan this", now: at(0))
        _ = gate.settle(now: at(1.0))
        _ = gate.consume("hey dojo scan this I found doctor Reyes should I add it to", now: at(6))
        gate.awaitConfirmation(now: at(6.5))

        XCTAssertNil(gate.consume("hey dojo scan this I found doctor Reyes should I add it to your calendar", now: at(6.7)))
        XCTAssertTrue(gate.isAwaitingConfirmation)
        // …and the real answer still lands.
        XCTAssertEqual(
            gate.consume("hey dojo scan this I found doctor Reyes should I add it to your calendar yes", now: at(9)),
            .confirmation(true)
        )
    }

    func testAnswerWithoutPendingConfirmationIsIgnored() {
        XCTAssertNil(gate.consume("yes", now: at(0)))
        XCTAssertNil(gate.consume("no", now: at(1)))
        XCTAssertFalse(gate.hasPendingCommand)
    }

    func testConfirmationWindowExpires() {
        gate.awaitConfirmation(now: at(0))
        XCTAssertNil(gate.consume("yes", now: at(46)))
        XCTAssertFalse(gate.isAwaitingConfirmation)
    }

    /// Saying a new "Hey Dojo" command instead of answering closes the question.
    func testNewCommandSupersedesPendingConfirmation() {
        gate.awaitConfirmation(now: at(0))
        XCTAssertNil(gate.consume("hey dojo read this to me", now: at(2)))
        XCTAssertEqual(gate.settle(now: at(3)), .command("read this to me"))
        XCTAssertFalse(gate.isAwaitingConfirmation)
    }

    /// "Hey Dojo, yes" is delivered as a command; the router treats it as the
    /// answer. It must not also be delivered as a bare confirmation.
    func testWakeWordYesIsACommandNotADoubleAnswer() {
        gate.awaitConfirmation(now: at(0))
        XCTAssertNil(gate.consume("hey dojo yes", now: at(2)))
        XCTAssertEqual(gate.settle(now: at(3)), .command("yes"))
        XCTAssertFalse(gate.isAwaitingConfirmation)
    }

    /// New segment during the confirmation window: the answer arrives alone.
    func testAnswerInFreshSegment() {
        _ = gate.consume("hey dojo scan this should I add it to your calendar", now: at(0))
        gate.awaitConfirmation(now: at(6))
        XCTAssertNil(gate.consume("", now: at(7)))
        XCTAssertEqual(gate.consume("yes", now: at(8)), .confirmation(true))
    }
}
