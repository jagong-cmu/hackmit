import Foundation

/// In-memory calendar for development and for Workstream B until
/// `GoogleCalendarService` lands on `main`.
final class MockCalendarService: CalendarService {
    private(set) var events: [CalendarEvent]

    init(events: [CalendarEvent] = []) {
        self.events = events
    }

    func createEvent(title: String, start: Date, end: Date?) async throws {
        events.append(CalendarEvent(title: title, start: start, end: end))
    }

    func todaysEvents() async throws -> [CalendarEvent] {
        let calendar = Calendar.current
        return events
            .filter { calendar.isDateInToday($0.start) }
            .sorted { $0.start < $1.start }
    }
}
