import Foundation

/// Features 1 and 2: parse a spoken calendar request, act on the calendar,
/// speak the result back through the glasses.
///
/// The mic and wake word live in `VoiceCommandRouter`, which hands every
/// "Hey Dojo …" to one feature; this is the feature that handles anything the
/// backend parsed as a calendar intent. Feature 2 (daily briefing) reuses the
/// same parsing path — it is another intent, not another listener.
@MainActor
final class SchedulingCoordinator {
    private let glasses: GlassesSession
    private let calendar: CalendarService
    private let intents: IntentClient

    init(glasses: GlassesSession, calendar: CalendarService, intents: IntentClient) {
        self.glasses = glasses
        self.calendar = calendar
        self.intents = intents
    }

    /// Parse and perform in one step. The router uses `perform` directly
    /// (it parses once and dispatches across features); this is for tests.
    func handle(_ command: String) async {
        do {
            await perform(try await intents.parse(command: command))
        } catch {
            await glasses.speak("Sorry, something went wrong. Please try again.")
        }
    }

    /// Acts on an already-parsed intent. Only calendar intents belong here —
    /// the router sends the camera and call intents to their own features.
    func perform(_ intent: VoiceIntent) async {
        switch intent {
        case let .createEvent(title, start, end):
            do {
                try await calendar.createEvent(title: title, start: start, end: end, location: nil)
                await glasses.speak("Okay. \(title), \(Self.spokenDateTime(start)).")
            } catch {
                await glasses.speak("Sorry, I couldn't save that to your calendar. Please try again.")
            }

        case .dailyBriefing:
            await speakBriefing()

        case let .unknown(reason):
            let detail = reason.isEmpty ? "" : " \(reason)"
            await glasses.speak("Sorry, I didn't catch that.\(detail)")

        case .scanCard, .readText, .checkAd, .callEmergency, .callContact:
            // Routed elsewhere by VoiceCommandRouter; reaching this means a
            // caller bypassed it. Say something rather than silently dropping it.
            await glasses.speak("Sorry, I didn't catch that.")
        }
    }

    private func speakBriefing() async {
        do {
            let events = try await calendar.todaysEvents()

            guard !events.isEmpty else {
                await glasses.speak("You have nothing scheduled today.")
                return
            }

            let items = events
                .map { "\($0.title) at \(Self.spokenTime($0.start))" }
                .joined(separator: ", then ")
            let count = events.count == 1 ? "one thing" : "\(events.count) things"
            await glasses.speak("You have \(count) today. \(items).")
        } catch {
            await glasses.speak("Sorry, I couldn't reach your calendar.")
        }
    }

    // MARK: - Speaking dates out loud

    /// Everything the wearer hears is spoken, so dates have to read the way a
    /// person would say them — never "2026-09-20T14:00".
    static func spokenDateTime(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = spokenTime(date)

        if calendar.isDateInToday(date) { return "today at \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow at \(time)" }

        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return "\(formatter.string(from: date)) at \(time)"
    }

    static func spokenTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
