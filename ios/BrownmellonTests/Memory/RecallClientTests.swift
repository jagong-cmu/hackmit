import XCTest
@testable import Brownmellon

/// What leaves the phone for general recall: the question, the clock, and at
/// most 100 notes — never a coordinate.
@MainActor
final class RecallClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func located(_ text: String, ageSeconds: TimeInterval, kind: MemoryNote.Kind = .general) -> MemoryNote {
        MemoryNote(
            kind: kind, text: text, signText: kind == .parking ? "Level 3, Row F" : nil,
            createdAt: now.addingTimeInterval(-ageSeconds),
            latitude: 42.3556, longitude: -71.0648, horizontalAccuracy: 10
        )
    }

    func testPayloadNeverContainsCoordinates() throws {
        let payload = RecallClient.payload(
            question: "where did i park",
            notes: [located("i parked in section b", ageSeconds: 60, kind: .parking), located("keys on the hook", ageSeconds: 120)],
            now: now,
            timeZone: newYork
        )
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(payload), encoding: .utf8))

        for forbidden in ["latitude", "longitude", "horizontalAccuracy", "42.35", "-71.06"] {
            XCTAssertFalse(json.contains(forbidden), "\(forbidden) must not be serialized: \(json)")
        }
        for expected in ["\"question\":\"where did i park\"", "\"kind\":\"parking\"", "\"signText\":\"Level 3, Row F\"", "\"timeZone\":\"America\\/New_York\""] {
            XCTAssertTrue(json.contains(expected), "\(expected) missing from \(json)")
        }
    }

    func testMissingSignTextIsSentAsExplicitNull() throws {
        let payload = RecallClient.payload(question: "q", notes: [located("keys", ageSeconds: 1)], now: now, timeZone: newYork)
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(payload), encoding: .utf8))
        XCTAssertTrue(json.contains("\"signText\":null"), "backend schema is nullable, not optional: \(json)")
    }

    func testTimestampsCarryTheWearersOffset() {
        let payload = RecallClient.payload(question: "q", notes: [located("keys", ageSeconds: 0)], now: now, timeZone: newYork)
        // 1_800_000_000 is 2027-01-15T08:00:00Z; New York is UTC-5 in January.
        XCTAssertEqual(payload.now, "2027-01-15T03:00:00-05:00")
        XCTAssertEqual(payload.notes.first?.createdAt, "2027-01-15T03:00:00-05:00")
        XCTAssertEqual(payload.timeZone, "America/New_York")
    }

    func testPayloadIsCappedAtOneHundredNewestFirst() {
        let notes = (0..<130).map { located("note \($0)", ageSeconds: Double($0)) }   // 0 is newest
        let payload = RecallClient.payload(question: "q", notes: notes.shuffled(), now: now, timeZone: newYork)

        XCTAssertEqual(payload.notes.count, RecallClient.maxNotes)
        XCTAssertEqual(payload.notes.first?.text, "note 0")
        XCTAssertEqual(payload.notes.last?.text, "note 99")
    }

    func testVisionBackendClientReadsSignsThroughTheReadMode() {
        // Compile-time proof that production wiring satisfies the protocol.
        let reader: ParkingSignReader = VisionBackendClient()
        XCTAssertNotNil(reader)
    }
}
