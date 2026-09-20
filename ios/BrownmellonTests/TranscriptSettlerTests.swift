import XCTest
@testable import Brownmellon

/// On hardware the recognizer streams growing partials for one sentence; the
/// settler must turn those into exactly one delivery of the finished text.
@MainActor
final class TranscriptSettlerTests: XCTestCase {
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    func testGrowingPartialsDeliverOnceWithTheLastText() async {
        var delivered: [String] = []
        let settler = TranscriptSettler(settleInterval: 0.05) { delivered.append($0) }

        settler.ingest("hey", isFinal: false)
        settler.ingest("hey dojo", isFinal: false)
        settler.ingest("hey dojo remember", isFinal: false)
        settler.ingest("hey dojo remember I parked in section B", isFinal: false)

        XCTAssertEqual(delivered, [], "nothing is delivered while the text is still changing")
        await settle()
        XCTAssertEqual(delivered, ["hey dojo remember I parked in section B"])
    }

    func testFinalResultDeliversImmediately() {
        var delivered: [String] = []
        let settler = TranscriptSettler(settleInterval: 10) { delivered.append($0) }

        settler.ingest("hey dojo what do I have today", isFinal: true)

        XCTAssertEqual(delivered, ["hey dojo what do I have today"])
    }

    func testIdenticalTextIsNotDeliveredTwice() async {
        var delivered: [String] = []
        let settler = TranscriptSettler(settleInterval: 0.05) { delivered.append($0) }

        settler.ingest("hey dojo scan this", isFinal: false)
        await settle()
        // The recognizer often re-reports the settled sentence as its final result.
        settler.ingest("hey dojo scan this", isFinal: true)

        XCTAssertEqual(delivered, ["hey dojo scan this"])
    }

    func testResetAllowsTheSameSentenceAgain() async {
        var delivered: [String] = []
        let settler = TranscriptSettler(settleInterval: 0) { delivered.append($0) }

        settler.ingest("hey dojo what was that", isFinal: false)
        settler.reset()
        settler.ingest("hey dojo what was that", isFinal: false)

        XCTAssertEqual(delivered, ["hey dojo what was that", "hey dojo what was that"])
    }

    func testEmptyOrWhitespaceTextIsNeverDelivered() async {
        var delivered: [String] = []
        let settler = TranscriptSettler(settleInterval: 0) { delivered.append($0) }

        settler.ingest("", isFinal: true)
        settler.ingest("   ", isFinal: false)

        XCTAssertEqual(delivered, [])
    }

    func testResetCancelsAPendingDelivery() async {
        var delivered: [String] = []
        let settler = TranscriptSettler(settleInterval: 0.05) { delivered.append($0) }

        settler.ingest("hey dojo read this", isFinal: false)
        settler.reset()
        await settle()

        XCTAssertEqual(delivered, [], "a fresh recognition task must not deliver the old task's partial")
    }
}
