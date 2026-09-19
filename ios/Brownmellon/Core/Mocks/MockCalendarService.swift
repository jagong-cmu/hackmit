import Foundation

/// Stand-in for the real Google Calendar-backed CalendarService (shared
/// foundation — owned by whichever of Workstream A/B builds it first,
/// see PRD.md § Foundation). In-memory only; resets on relaunch.
@MainActor
final class MockCalendarService: CalendarService {
    private(set) var events: [CalendarEvent] = []

    func createEvent(title: String, start: Date, end: Date?, location: String?) async throws -> CalendarEvent {
        let event = CalendarEvent(id: UUID().uuidString, title: title, start: start, end: end, location: location)
        events.append(event)
        return event
    }

    func todaysEvents() async throws -> [CalendarEvent] {
        let calendar = Calendar.current
        return events.filter { calendar.isDateInToday($0.start) }
    }
}
