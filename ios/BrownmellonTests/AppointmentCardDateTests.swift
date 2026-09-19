import XCTest
@testable import Brownmellon

/// The backend returns card times without a timezone (a paper card has none).
/// This regression bit on the first live test: the default ISO8601 parser
/// rejected every real card as "no result".
final class AppointmentCardDateTests: XCTestCase {
    func testAcceptsOffsetlessLocalTime() {
        let date = AppointmentCardScanViewModel.parseCardDate("2026-10-06T14:30:00")
        XCTAssertNotNil(date)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date!)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 10)
        XCTAssertEqual(parts.day, 6)
        XCTAssertEqual(parts.hour, 14)
        XCTAssertEqual(parts.minute, 30)
    }

    func testStillAcceptsExplicitOffset() {
        XCTAssertEqual(
            AppointmentCardScanViewModel.parseCardDate("2026-10-06T14:30:00-04:00"),
            ISO8601DateFormatter().date(from: "2026-10-06T18:30:00Z")
        )
    }

    func testRejectsGarbage() {
        XCTAssertNil(AppointmentCardScanViewModel.parseCardDate("Tuesday at 2:30"))
    }
}
