import Foundation

/// Thin UI wrapper around `SchedulingCoordinator` (features 1–2, see PRD.md).
/// The coordinator itself is UI-less by design — it only listens and speaks —
/// so this exposes just enough state for a screen: whether it's listening,
/// and a manual "try it" path for Simulator/demo use where there's no real
/// mic input or speaker to watch.
@MainActor
final class SchedulingViewModel: ObservableObject {
    @Published var draftCommand: String = ""
    @Published private(set) var lastResponse: String?
    @Published private(set) var isListening = false

    private let coordinator: SchedulingCoordinator

    init(glasses: GlassesSession, calendar: CalendarService, backendBaseURL: URL) {
        let intents = IntentClient(endpoint: backendBaseURL.appendingPathComponent("api/parse-intent"))
        self.coordinator = SchedulingCoordinator(glasses: glasses, calendar: calendar, intents: intents)

        if let mock = glasses as? MockGlassesSession {
            mock.onSpeak = { [weak self] text in self?.lastResponse = text }
        }
    }

    func start() {
        coordinator.start()
        isListening = true
    }

    func stop() {
        coordinator.stop()
        isListening = false
    }

    /// Exercises the same path a real "Hey Dojo" utterance would, without
    /// needing a mic — see `SchedulingCoordinator.handle`'s own doc comment.
    func tryCommand() async {
        let command = draftCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        draftCommand = ""
        await coordinator.handle(command)
    }
}
