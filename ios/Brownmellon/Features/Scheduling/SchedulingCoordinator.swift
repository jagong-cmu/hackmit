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
    /// Whether `start()` is in effect — the *intent* to listen. The mic itself
    /// is closed while a command runs (see `handle`).
    private var isListening = false
    /// True from the moment a command is accepted until its reply has been
    /// spoken. The mic is closed for that window; a typed command that arrives
    /// during it is declined (see `VoiceAssistant.handle`).
    private(set) var isHandlingCommand = false

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
        isListening = true
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
        isListening = false
        glasses.stopListening()
    }

    /// Exposed for tests and for a Setup-Mode "try it" button.
    ///
    /// The mic is closed for the whole command and reopened afterwards. Three
    /// reasons: a live recognizer keeps appending to one transcript, so the
    /// wearer's next sentence would otherwise arrive glued to this command
    /// ("…parked in section b hey dojo what do i have today"); anything said
    /// while a slow handler runs (a companion's "hold on, it's taking a
    /// photo") would be transcribed onto the command and dispatched again;
    /// and our own reply would be transcribed too. Reopening starts the next
    /// utterance from an empty transcript.
    func handle(_ command: String) async {
        guard !isHandlingCommand else { return }
        isHandlingCommand = true
        if isListening { glasses.stopListening() }
        defer {
            isHandlingCommand = false
            if isListening { start() }
        }

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
