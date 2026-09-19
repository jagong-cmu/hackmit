import Foundation
import UIKit
import AVFoundation
import PhotosUI

/// Stand-in for the real DAT-backed GlassesSession (shared foundation,
/// not yet built — see PRD.md § Foundation). Lets Workstream B develop
/// and demo entirely on Simulator, no glasses or physical device needed:
///  - `speak` uses real on-device text-to-speech, so the UX is audible.
///  - `capturePhoto` opens the system photo picker so a developer can
///    hand it a sample appointment-card / document photo, standing in
///    for what the glasses camera would have captured.
///  - `startListening` / `stopListening` store the transcript callback and
///    expose `simulateTranscript(_:)` so Workstream A's wake-word pipeline
///    (`SchedulingCoordinator`, "Hey Dojo") is exercisable on Simulator —
///    call it from a debug UI or a test in place of real mic input.
///    Vision's own features (`AppointmentCardScanView` / `ReadToMeView`)
///    still use an explicit on-screen button rather than the wake word.
///    Swap this session out for the real DAT-backed one once that lands.
@MainActor
final class MockGlassesSession: NSObject, GlassesSession {
    private let synthesizer = AVSpeechSynthesizer()
    private var photoPickerContinuation: CheckedContinuation<UIImage, Error>?
    private var onTranscript: ((String) -> Void)?
    private(set) var isListening = false

    /// Debug/demo hook — fires alongside real TTS so a screen with no
    /// speaker can show what the glasses just said (e.g. `SchedulingView`).
    var onSpeak: ((String) -> Void)?

    func speak(_ text: String) async {
        onSpeak?(text)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    func startListening(onTranscript: @escaping (String) -> Void) {
        self.onTranscript = onTranscript
        isListening = true
    }

    func stopListening() {
        onTranscript = nil
        isListening = false
    }

    /// Test/demo hook — pretend the wearer said something out loud.
    /// No-op if nothing has called `startListening` yet.
    func simulateTranscript(_ text: String) {
        onTranscript?(text)
    }

    func capturePhoto() async throws -> UIImage {
        guard let presenter = Self.topViewController() else {
            throw MockGlassesSessionError.noPresenter
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.photoPickerContinuation = continuation

            var config = PHPickerConfiguration()
            config.filter = .images
            config.selectionLimit = 1
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            presenter.present(picker, animated: true)
        }
    }

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              var top = scene.keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

extension MockGlassesSession: PHPickerViewControllerDelegate {
    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        Task { @MainActor in
            picker.dismiss(animated: true)
        }

        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else {
            Task { @MainActor in
                self.photoPickerContinuation?.resume(throwing: MockGlassesSessionError.noImageSelected)
                self.photoPickerContinuation = nil
            }
            return
        }

        provider.loadObject(ofClass: UIImage.self) { image, error in
            Task { @MainActor in
                if let image = image as? UIImage {
                    self.photoPickerContinuation?.resume(returning: image)
                } else {
                    self.photoPickerContinuation?.resume(throwing: error ?? MockGlassesSessionError.noImageSelected)
                }
                self.photoPickerContinuation = nil
            }
        }
    }
}

enum MockGlassesSessionError: Error {
    case noPresenter
    case noImageSelected
}

private extension UIWindowScene {
    var keyWindow: UIWindow? {
        windows.first(where: \.isKeyWindow)
    }
}
