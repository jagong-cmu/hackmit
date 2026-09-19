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
///  - `startListening` / `stopListening` are no-ops here — Workstream B's
///    features are triggered by an explicit on-screen button for now
///    (see `AppointmentCardScanView` / `ReadToMeView`), not by the real
///    "Hey Brownmellon" keyword spotter, which is Workstream A's
///    infrastructure. Swap this session out once that's ready to wire
///    real voice triggers.
@MainActor
final class MockGlassesSession: NSObject, GlassesSession {
    private let synthesizer = AVSpeechSynthesizer()
    private var photoPickerContinuation: CheckedContinuation<UIImage, Error>?

    func speak(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    func startListening(onTranscript: @escaping (String) -> Void) {
        // No-op in the mock — see type doc. Real implementation streams
        // DAT mic audio and calls onTranscript with recognized speech.
    }

    func stopListening() {
        // No-op in the mock.
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
