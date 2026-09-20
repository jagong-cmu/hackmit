import XCTest
import CoreLocation
@testable import Brownmellon

/// Distance, direction and elapsed time are spoken, never shown, so every
/// branch of the sentence builder is pinned here against the PRD's table.
final class ParkingSpeechTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Distance

    func testUnderAThousandFeetIsSpokenInFeetToTheNearestTen() {
        XCTAssertEqual(ParkingSpeech.spokenDistance(meters: 91.44), "about 300 feet")
        XCTAssertEqual(ParkingSpeech.spokenDistance(meters: 92.9), "about 300 feet", "304.8 ft rounds to 300")
        XCTAssertEqual(ParkingSpeech.spokenDistance(meters: 3), "about 10 feet", "never says zero feet")
        XCTAssertEqual(ParkingSpeech.spokenDistance(meters: 0), "about 10 feet")
        XCTAssertEqual(ParkingSpeech.spokenDistance(meters: 300), "about 980 feet")
    }

    func testAThousandFeetAndBeyondIsTenthsOfAMile() {
        XCTAssertEqual(ParkingSpeech.spokenDistance(meters: 304.8), "about 0.2 miles", "exactly 1000 ft")
        XCTAssertEqual(ParkingSpeech.spokenDistance(meters: 1609.344), "about 1 mile")
        XCTAssertEqual(ParkingSpeech.spokenDistance(meters: 2414), "about 1.5 miles")
        XCTAssertEqual(ParkingSpeech.spokenDistance(meters: 3218.7), "about 2 miles")
        XCTAssertEqual(ParkingSpeech.spokenDistance(meters: 800), "about 0.5 miles")
    }

    // MARK: - Direction

    func testEightCompassPoints() {
        XCTAssertEqual(ParkingSpeech.compassPoint(bearingDegrees: 0), "north")
        XCTAssertEqual(ParkingSpeech.compassPoint(bearingDegrees: 45), "northeast")
        XCTAssertEqual(ParkingSpeech.compassPoint(bearingDegrees: 90), "east")
        XCTAssertEqual(ParkingSpeech.compassPoint(bearingDegrees: 135), "southeast")
        XCTAssertEqual(ParkingSpeech.compassPoint(bearingDegrees: 180), "south")
        XCTAssertEqual(ParkingSpeech.compassPoint(bearingDegrees: 225), "southwest")
        XCTAssertEqual(ParkingSpeech.compassPoint(bearingDegrees: 270), "west")
        XCTAssertEqual(ParkingSpeech.compassPoint(bearingDegrees: 315), "northwest")
    }

    func testCompassPointBoundaries() {
        XCTAssertEqual(ParkingSpeech.compassPoint(bearingDegrees: 22.4), "north")
        XCTAssertEqual(ParkingSpeech.compassPoint(bearingDegrees: 22.5), "northeast")
        XCTAssertEqual(ParkingSpeech.compassPoint(bearingDegrees: 359), "north")
        XCTAssertEqual(ParkingSpeech.compassPoint(bearingDegrees: 360), "north")
        XCTAssertEqual(ParkingSpeech.compassPoint(bearingDegrees: -90), "west", "negative bearings wrap")
    }

    func testBearingFromCoordinates() {
        let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        XCTAssertEqual(ParkingSpeech.bearingDegrees(from: origin, to: .init(latitude: 1, longitude: 0)), 0, accuracy: 0.01, "due north")
        XCTAssertEqual(ParkingSpeech.bearingDegrees(from: origin, to: .init(latitude: 0, longitude: 1)), 90, accuracy: 0.01, "due east")
        XCTAssertEqual(ParkingSpeech.bearingDegrees(from: origin, to: .init(latitude: -1, longitude: 0)), 180, accuracy: 0.01, "due south")
        XCTAssertEqual(ParkingSpeech.bearingDegrees(from: origin, to: .init(latitude: 0, longitude: -1)), 270, accuracy: 0.01, "due west")
        XCTAssertEqual(ParkingSpeech.bearingDegrees(from: origin, to: .init(latitude: 1, longitude: 1)), 45, accuracy: 0.5, "northeast")
    }

    func testSpokenOffsetCombinesDistanceAndDirection() {
        // ~100 m north-east of Boston Common: 300 ft-ish to the northeast.
        let here = CLLocation(latitude: 42.3550, longitude: -71.0656)
        let car = CLLocation(latitude: 42.3556, longitude: -71.0648)
        let spoken = ParkingSpeech.spokenOffset(from: here, to: car)
        XCTAssertTrue(spoken.hasPrefix("about "), spoken)
        XCTAssertTrue(spoken.hasSuffix(" feet to the northeast"), spoken)
    }

    // MARK: - Elapsed time

    func testUnderAMinuteIsJustNow() {
        XCTAssertEqual(ParkingSpeech.spokenElapsed(from: now, to: now), "just now")
        XCTAssertEqual(ParkingSpeech.spokenElapsed(from: now.addingTimeInterval(-59), to: now), "just now")
    }

    func testElapsedIsSpelledOut() {
        XCTAssertEqual(ParkingSpeech.spokenElapsed(from: now.addingTimeInterval(-2 * 3600), to: now), "about two hours ago")
        XCTAssertEqual(ParkingSpeech.spokenElapsed(from: now.addingTimeInterval(-5 * 60), to: now), "about five minutes ago")
        XCTAssertEqual(ParkingSpeech.spokenElapsed(from: now.addingTimeInterval(-3 * 86_400), to: now), "about three days ago")
    }

    func testStaleAfterTwentyFourHours() {
        XCTAssertFalse(ParkingSpeech.isStale(createdAt: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertTrue(ParkingSpeech.isStale(createdAt: now.addingTimeInterval(-25 * 3600), now: now))
    }

    // MARK: - Recall sentence (PRD table)

    private func parkingNote(text: String = "", signText: String? = nil, ageSeconds: TimeInterval, located: Bool) -> MemoryNote {
        MemoryNote(
            kind: .parking,
            text: text,
            signText: signText,
            createdAt: now.addingTimeInterval(-ageSeconds),
            latitude: located ? 42.3556 : nil,
            longitude: located ? -71.0648 : nil,
            horizontalAccuracy: located ? 10 : nil
        )
    }

    private let here = CLLocation(latitude: 42.3550, longitude: -71.0656)

    func testSignTextAndBothLocations() {
        let note = parkingNote(signText: "Level 3, Row F", ageSeconds: 2 * 3600, located: true)
        let spoken = ParkingSpeech.recallSentence(for: note, here: here, now: now)
        XCTAssertTrue(spoken.hasPrefix("You parked about two hours ago. The sign said Level 3, Row F. Your car is about "), spoken)
        XCTAssertTrue(spoken.hasSuffix(" feet to the northeast."), spoken)
    }

    func testLocationWithoutSign() {
        let note = parkingNote(ageSeconds: 2 * 3600, located: true)
        let spoken = ParkingSpeech.recallSentence(for: note, here: here, now: now)
        XCTAssertTrue(spoken.hasPrefix("You parked about two hours ago, about "), spoken)
        XCTAssertTrue(spoken.hasSuffix(" feet to the northeast of here."), spoken)
    }

    func testTextOnly() {
        let note = parkingNote(text: "i parked in section b", ageSeconds: 2 * 3600, located: false)
        XCTAssertEqual(
            ParkingSpeech.recallSentence(for: note, here: here, now: now),
            "You told me about two hours ago: I parked in section B."
        )
    }

    func testTextOnlyJustNow() {
        let note = parkingNote(text: "i parked in section b", ageSeconds: 5, located: false)
        XCTAssertEqual(
            ParkingSpeech.recallSentence(for: note, here: nil, now: now),
            "You told me just now: I parked in section B."
        )
    }

    func testTextWithLocationAddsTheDistance() {
        let note = parkingNote(text: "i parked in section b", ageSeconds: 90, located: true)
        let spoken = ParkingSpeech.recallSentence(for: note, here: here, now: now)
        XCTAssertTrue(spoken.hasPrefix("You told me about one minute ago: I parked in section B. Your car is about "), spoken)
    }

    func testSignWithoutCurrentLocationSkipsTheDistance() {
        let note = parkingNote(signText: "Level 3, Row F", ageSeconds: 2 * 3600, located: true)
        XCTAssertEqual(
            ParkingSpeech.recallSentence(for: note, here: nil, now: now),
            "You parked about two hours ago. The sign said Level 3, Row F."
        )
    }

    func testOldNoteGetsThePrefix() {
        let note = parkingNote(text: "i parked in section b", ageSeconds: 30 * 3600, located: false)
        XCTAssertEqual(
            ParkingSpeech.recallSentence(for: note, here: nil, now: now),
            "This might be old — you told me about one day ago: I parked in section B."
        )
    }

    // MARK: - Sign text from OCR

    func testSignTextTidiesLineBreaksAndShoutingCaps() {
        XCTAssertEqual(ParkingSpeech.signText(fromOCR: "LEVEL 3\nROW F"), "Level 3, Row F")
        XCTAssertEqual(ParkingSpeech.signText(fromOCR: "  Section  B  \n\n"), "Section B")
        XCTAssertEqual(ParkingSpeech.signText(fromOCR: ""), "")
        XCTAssertEqual(ParkingSpeech.signText(fromOCR: "P2"), "P2", "short codes are left alone")
    }

    func testSignTextIsCappedAtAWordBoundary() {
        let wall = Array(repeating: "words", count: 60).joined(separator: " ")
        let capped = ParkingSpeech.signText(fromOCR: wall, maxLength: 120)
        XCTAssertLessThanOrEqual(capped.count, 120)
        XCTAssertFalse(capped.hasSuffix(" "))
        XCTAssertTrue(capped.hasSuffix("words"), "cut between words, not mid-word: \(capped)")
    }
}
