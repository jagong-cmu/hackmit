import Foundation
import Combine

/// Thin UI adapter over the app-wide `VoiceAssistant` (features 1–2, see
/// PRD.md). The assistant itself is UI-less by design — it only listens and
/// speaks, for the app's whole lifetime — so this exposes just enough state
/// for a screen: whether it's listening, what it last said, and a manual
/// "try it" path for Simulator/demo use where there's no real mic input or
/// speaker to watch.
@MainActor
final class SchedulingViewModel: ObservableObject {
    @Published var draftCommand: String = ""
    @Published private(set) var lastResponse: String?
    @Published private(set) var isListening = false

    private let assistant: VoiceAssistant

    init(assistant: VoiceAssistant) {
        self.assistant = assistant
        assistant.$lastResponse.assign(to: &$lastResponse)
        assistant.$isListening.assign(to: &$isListening)
    }

    /// Exercises the same path a real "Hey Dojo" utterance would, without
    /// needing a mic — see `SchedulingCoordinator.handle`'s own doc comment.
    func tryCommand() async {
        let command = draftCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        draftCommand = ""
        await assistant.handle(command)
    }
}
