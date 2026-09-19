import Foundation
import UIKit

/// Feature 5: one still image is assessed using both visible text and visual
/// content, then optionally checked against up to two independently grounded
/// web targets. The result is advisory and never writes scan history.
@MainActor
final class AdScamCheckViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case capturing
        case checking
        case completed(ScamCheckBackendClient.Result)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let glasses: GlassesSession
    private let backend: ScamCheckBackendClient

    init(
        glasses: GlassesSession,
        backend: ScamCheckBackendClient = ScamCheckBackendClient(),
        router: VoiceCommandRouter? = nil
    ) {
        self.glasses = glasses
        self.backend = backend

        router?.setScamHandler { [weak self] in
            await self?.checkAd()
        }
    }

    /// Captures exactly one still image per accepted trigger.
    func checkAd() async {
        if case .capturing = state { return }
        if case .checking = state { return }
        state = .capturing
        do {
            let photo = try await glasses.capturePhoto()
            state = .checking
            let result = try await backend.check(photo)
            state = .completed(result)
            await glasses.speak(spokenText(for: result))
        } catch {
            state = .failed(String(describing: error))
            await glasses.speak("Something went wrong checking that advertisement. Please try again.")
        }
    }

    private func spokenText(for result: ScamCheckBackendClient.Result) -> String {
        let summary = result.spokenSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = result.safeAction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return action }
        guard !action.isEmpty else { return summary }

        // The backend keeps these as separate fields. Avoid saying the same
        // sentence twice if a future server response repeats itself.
        if summary.caseInsensitiveCompare(action) == .orderedSame {
            return summary
        }
        return "\(summary) \(action)"
    }
}
