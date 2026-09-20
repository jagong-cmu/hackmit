import Foundation
import UIKit

/// Feature 4 ("Read this to me") — see PRD.md.
/// Flow: one photo -> backend OCR/vision extracts text -> read aloud.
/// No confirmation step needed (nothing is written anywhere), and no
/// capture-button fallback exists — DAT doesn't expose the glasses'
/// button as an event to third-party apps, so this stays voice-only.
@MainActor
final class ReadToMeViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case capturing
        case reading
        case done(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let glasses: GlassesSession
    private let backend: VisionBackendClient

    init(glasses: GlassesSession, backend: VisionBackendClient = VisionBackendClient()) {
        self.glasses = glasses
        self.backend = backend
    }

    /// Entry point for both triggers: "Hey Dojo, read this to me" (via
    /// `VoiceCommandRouter`) and the on-screen button.
    func readThisToMe() async {
        state = .capturing
        do {
            let photo = try await glasses.capturePhoto()
            state = .reading
            let result = try await backend.readAloud(photo)

            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .failed("empty")
                await glasses.speak("I couldn't find any text in that.")
                return
            }

            state = .done(result.text)
            await glasses.speak(result.text)
        } catch {
            state = .failed(String(describing: error))
            await glasses.speak(BackendErrors.spokenMessage(for: error, otherwise: "Something went wrong reading that. Let's try again."))
        }
    }
}
