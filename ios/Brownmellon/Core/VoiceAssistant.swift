import Foundation
import Combine

/// The one "Hey Dojo" pipeline for the whole app: owns the
/// `SchedulingCoordinator` (wake word → handler chain → calendar intents),
/// keeps the mic listening for the app's lifetime rather than a tab's, and
/// mirrors what the glasses last said so any screen can show it.
///
/// `BrownmellonApp` builds exactly one of these with every feature's
/// `VoiceCommandHandler` in `handlers` (see PRD-foundation-v2 § 7) and starts
/// it once from the root view. Feature view models that also act as handlers
/// must be the *same instances* passed to their views — otherwise the voice
/// path and the on-screen path act on different objects.
@MainActor
final class VoiceAssistant: ObservableObject {
    /// The last thing spoken through the glasses (fed by the session's
    /// `onSpeak` hook, so it fires on Simulator and hardware alike).
    @Published private(set) var lastResponse: String?
    /// Whether `start()` has asked the session to listen. On hardware,
    /// `DATGlassesSession.isListening` reports what the mic is actually doing.
    @Published private(set) var isListening = false

    private let coordinator: SchedulingCoordinator

    init(
        glasses: GlassesSession,
        calendar: CalendarService,
        intents: IntentClient,
        handlers: [VoiceCommandHandler] = []
    ) {
        coordinator = SchedulingCoordinator(
            glasses: glasses,
            calendar: calendar,
            intents: intents,
            handlers: handlers
        )

        // Chain rather than replace any hook already installed, so a test or
        // debug screen that set `onSpeak` before building the assistant keeps
        // receiving speech.
        let showResponse: (String) -> Void = { [weak self] text in self?.lastResponse = text }
        if let mock = glasses as? MockGlassesSession {
            let previous = mock.onSpeak
            mock.onSpeak = { text in
                previous?(text)
                showResponse(text)
            }
        } else if let real = glasses as? DATGlassesSession {
            let previous = real.onSpeak
            real.onSpeak = { text in
                previous?(text)
                showResponse(text)
            }
        }
    }

    /// Production wiring: intents go to `api/parse-intent` on the backend.
    convenience init(
        glasses: GlassesSession,
        calendar: CalendarService,
        backendBaseURL: URL,
        handlers: [VoiceCommandHandler] = []
    ) {
        self.init(
            glasses: glasses,
            calendar: calendar,
            intents: IntentClient(endpoint: backendBaseURL.appendingPathComponent("api/parse-intent")),
            handlers: handlers
        )
    }

    /// Begins listening for the wake word. Called once at launch; nothing
    /// stops it on tab changes.
    func start() {
        coordinator.start()
        isListening = true
    }

    func stop() {
        coordinator.stop()
        isListening = false
    }

    /// Runs a command as if it had followed "Hey Dojo" — the Simulator/demo
    /// "Try it" field. Normalized exactly as the wake-word path normalizes
    /// speech, so every handler sees the same shape either way; then straight
    /// to the coordinator (works on both sessions). The real voice path is
    /// exercised via `MockGlassesSession.simulateTranscript` in tests.
    func handle(_ typed: String) async {
        // Speech can't arrive while a command runs (the mic is closed), but a
        // tap on "Try it" can — say so instead of silently dropping it.
        guard !coordinator.isHandlingCommand else {
            lastResponse = Self.busyMessage
            return
        }
        await coordinator.handle(WakeWordDetector.normalize(typed))
    }

    static let busyMessage = "One moment — I'm still working on the last one."
}
