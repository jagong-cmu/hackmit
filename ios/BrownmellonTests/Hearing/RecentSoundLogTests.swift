import XCTest
@testable import Brownmellon

final class RecentSoundLogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func ago(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(-seconds)
    }

    func testRecordsOnlyAtOrAboveMinimumConfidence() {
        let log = RecentSoundLog()
        log.record("door_bell", confidence: 0.39, at: ago(1))
        log.record("door_bell", confidence: 0.4, at: ago(1))
        log.record("knock", confidence: 0.95, at: ago(1))

        XCTAssertEqual(log.observations(now: now).map(\.identifier), ["door_bell", "knock"])
    }

    func testPrunesObservationsOlderThanTheWindow() {
        let log = RecentSoundLog(window: 60)
        log.record("dog_bark", confidence: 0.9, at: ago(61))
        log.record("door_bell", confidence: 0.9, at: ago(59))

        XCTAssertEqual(log.observations(now: now).map(\.identifier), ["door_bell"])
        XCTAssertNil(log.mostNotable(now: now.addingTimeInterval(2)), "everything ages out after a minute")
    }

    func testMostNotableIsNilWhenEmpty() {
        XCTAssertNil(RecentSoundLog().mostNotable(now: now))
    }

    func testMostNotablePicksTheMostConfidentOfTheLatestSound() {
        let log = RecentSoundLog()
        // An older, very confident dog bark…
        log.record("dog_bark", confidence: 0.99, at: ago(50))
        // …then a doorbell that showed up across three overlapping windows.
        log.record("door_bell", confidence: 0.55, at: ago(11.5))
        log.record("door_bell", confidence: 0.92, at: ago(10.75))
        log.record("knock", confidence: 0.45, at: ago(10.75))
        log.record("door_bell", confidence: 0.8, at: ago(10))

        let notable = log.mostNotable(now: now)
        XCTAssertEqual(notable?.identifier, "door_bell", "most recent sound wins over an older, louder one")
        XCTAssertEqual(notable?.confidence, 0.92, "…and within that sound, the most confident window")
    }

    func testCapacityIsBounded() {
        let log = RecentSoundLog(capacity: 3)
        for i in 0..<10 {
            log.record("knock", confidence: 0.9, at: ago(Double(10 - i)))
        }
        XCTAssertEqual(log.observations(now: now).count, 3)
        XCTAssertEqual(log.observations(now: now).last?.timestamp, ago(1), "keeps the newest")
    }

    func testClear() {
        let log = RecentSoundLog()
        log.record("knock", confidence: 0.9, at: ago(1))
        log.clear()
        XCTAssertTrue(log.observations(now: now).isEmpty)
    }
}
