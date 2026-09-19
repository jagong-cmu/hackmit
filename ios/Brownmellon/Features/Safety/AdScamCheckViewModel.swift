import Foundation
import UIKit

/// Feature 5 (Advertisement scam detection, OCR-only) — see PRD.md.
/// Flow: one photo -> backend OCR + text-pattern assessment -> spoken
/// result. Nothing is written anywhere, so unlike Features 1/3 there is
/// no confirm-before-write step — this is advisory only, by design.
@MainActor
final class AdScamCheckViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case capturing
        case checking
        case done(ScamCheckBackendClient.Result)
        /// OCR found no text to assess. Distinct from `.done` with low risk:
        /// we failed to read the ad, which is not the same as judging it safe.
        case unreadable(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let glasses: GlassesSession
    private let backend: ScamCheckBackendClient

    init(glasses: GlassesSession, backend: ScamCheckBackendClient = ScamCheckBackendClient()) {
        self.glasses = glasses
        self.backend = backend
    }

    /// Called on trigger — a button tap in this scaffold; wire to "Hey
    /// Dojo, check this ad" once Workstream A's wake-word router is
    /// extended to route non-scheduling commands here.
    func checkAd() async {
        state = .capturing
        do {
            let photo = try await glasses.capturePhoto()
            state = .checking
            let result = try await backend.check(photo)
            // Empty extractedText is the backend's FALLBACK — it could not read
            // the ad. Its scamRisk is "low" only because the enum has no other
            // resting value, so showing it as `.done` would render a green
            // "Low risk" checkmark for an ad nobody ever read. For a feature
            // warning vulnerable users about fraud, failure must not look like
            // safety. The spoken summary already draws this distinction.
            state = result.extractedText.isEmpty
                ? .unreadable(result.safeAction)
                : .done(result)
            await glasses.speak(spokenSummary(for: result))
        } catch {
            state = .failed(String(describing: error))
            await glasses.speak("Something went wrong checking that ad. Let's try again.")
        }
    }

    private func spokenSummary(for result: ScamCheckBackendClient.Result) -> String {
        switch result.scamRisk {
        case .high, .medium:
            return "This ad looks risky. \(result.safeAction)"
        case .low:
            return result.extractedText.isEmpty
                ? result.safeAction
                : "This ad doesn't show obvious warning signs, but I can't guarantee it's legitimate. \(result.safeAction)"
        }
    }
}
