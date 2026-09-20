import Foundation

/// Features 1 and 2 end to end: listen for "Hey Dojo", parse what follows,
/// act on the calendar, speak the result back through the glasses.
///
/// Feature 2 (daily briefing) deliberately reuses feature 1's trigger and
/// parsing path — it is another intent, not another listener.
@MainActor
final class SchedulingCoordinator {
    private let glasses: GlassesSession
    private let calendar: CalendarService
    private let intents: IntentClient
    private let listener: WakeWordListener
    /// Consulted in order before the calendar intent parser; the first one
    /// to return true owns the command (see `VoiceCommandHandler`).
    private let handlers: [VoiceCommandHandler]

    init(
        glasses: GlassesSession,
        calendar: CalendarService,
        intents: IntentClient,
        listener: WakeWordListener = WakeWordListener(),
        handlers: [VoiceCommandHandler] = []
    ) {
        self.glasses = glasses
        self.calendar = calendar
        self.intents = intents
        self.listener = listener
        self.handlers = handlers
    }

    func start() {
        glasses.startListening { [weak self] transcript in
            // The recognizer callback has no thread guarantees; hop to the main
            // actor before touching the listener's debounce state.
            Task { @MainActor [weak self] in
                guard let self, let command = self.listener.consume(transcript) else { return }
                await self.handle(command)
            }
        }
    }

    func stop() {
        glasses.stopListening()
    }

    /// Exposed for tests and for a Setup-Mode "try it" button.
    func handle(_ command: String) async {
        for handler in handlers {
            if await handler.handle(command) {
                listener.reset()
                return
            }
        }

        do {
            switch try await intents.parse(command: command) {
            case let .createEvent(title, start, end):
                try await calendar.createEvent(title: title, start: start, end: end, location: nil)
                await glasses.speak("Okay. \(title), \(Self.spokenDateTime(start)).")

            case .dailyBriefing:
                await speakBriefing()

            case let .unknown(reason):
                let detail = reason.isEmpty ? "" : " \(reason)"
                await glasses.speak("Sorry, I didn't catch that.\(detail)")
            }
        } catch {
            await glasses.speak("Sorry, something went wrong. Please try again.")
        }

        // Our own speech leaks into the mic; don't let it eat the next command.
        listener.reset()
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
