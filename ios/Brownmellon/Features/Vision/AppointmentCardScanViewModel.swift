import Foundation
import UIKit

/// Feature 3 (Appointment-card scanning) — see PRD.md.
/// Flow: one photo -> backend parses date/time/provider/location ->
/// spoken confirmation -> write to calendar only after confirmation.
@MainActor
final class AppointmentCardScanViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case capturing
        case parsing
        case awaitingConfirmation(title: String, start: Date, location: String?)
        case saved(CalendarEvent)
        case noResult
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let glasses: GlassesSession
    private let calendar: CalendarService
    private let backend: VisionBackendClient
    private var pendingResult: VisionBackendClient.AppointmentResult?

    init(glasses: GlassesSession, calendar: CalendarService, backend: VisionBackendClient = VisionBackendClient()) {
        self.glasses = glasses
        self.calendar = calendar
        self.backend = backend
    }

    /// Called when the wearer triggers this feature — a button tap in
    /// the mock UI today; will be called by Workstream A's keyword
    /// router once "Hey Brownmellon, scan this" is wired up for real.
    func scan() async {
        state = .capturing
        do {
            let photo = try await glasses.capturePhoto()
            state = .parsing
            let result = try await backend.scanAppointmentCard(photo)

            guard let title = result.title,
                  let startISO = result.startISO8601,
                  let start = Self.parseCardDate(startISO) else {
                pendingResult = nil
                state = .noResult
                await glasses.speak("I couldn't make out a date and time on that card. Want to try again, or add it by voice instead?")
                return
            }

            pendingResult = result
            state = .awaitingConfirmation(title: title, start: start, location: result.location)

            let dateDescription = DateFormatter.localizedString(from: start, dateStyle: .full, timeStyle: .short)
            await glasses.speak("I found: \(title), \(dateDescription). Should I add it to your calendar?")
        } catch {
            state = .failed(String(describing: error))
            await glasses.speak("Something went wrong reading that card. Let's try again.")
        }
    }

    /// Call after the wearer gives an affirmative spoken response.
    /// Never call this on a guess — no confirmation, no write (PRD design principle).
    func confirm() async {
        guard case .awaitingConfirmation(let title, let start, let location) = state,
              let result = pendingResult else { return }

        do {
            let end: Date? = result.endISO8601.flatMap(Self.parseCardDate)
            let event = try await calendar.createEvent(title: title, start: start, end: end, location: location)
            state = .saved(event)
            await glasses.speak("Done — added to your calendar.")
        } catch {
            state = .failed(String(describing: error))
            await glasses.speak("I couldn't save that to your calendar. Let's try again.")
        }
    }

    func decline() async {
        pendingResult = nil
        state = .idle
        await glasses.speak("Okay, I won't add it.")
    }

    /// A paper card has no timezone, so the backend returns local wall-clock
    /// time with no offset ("2026-10-06T14:30:00"). ISO8601DateFormatter's
    /// default rejects that, which made every real card read as "no result".
    /// Accept an offset if present, otherwise treat it as the phone's zone.
    nonisolated static func parseCardDate(_ string: String) -> Date? {
        let withOffset = ISO8601DateFormatter()
        if let date = withOffset.date(from: string) { return date }

        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return local.date(from: string)
    }
}
