import Foundation
import UIKit
import AVFoundation
import PhotosUI

/// Simulator stand-in for `DATGlassesSession` (the real Ray-Ban Meta
/// session). Lets every feature develop and demo entirely on Simulator, no
/// glasses or physical device needed:
///  - `speak` uses real on-device text-to-speech and, like the hardware
///    session, returns only once the utterance has finished playing.
///  - `capturePhoto` opens the system photo picker so a developer can
///    hand it a sample appointment-card / document photo, standing in
///    for what the glasses camera would have captured — or returns
///    `stubbedPhoto` when a test has set one.
///  - `startListening` / `stopListening` store the transcript callback and
///    expose `simulateTranscript(_:)` so the wake-word pipeline
///    (`VoiceAssistant` → `SchedulingCoordinator`, "Hey Dojo") is exercisable
///    on Simulator — call it from a debug UI or a test in place of real mic
///    input.
///  - `startAudioTap` / `stopAudioTap` store the buffer callback and expose
///    `simulateAudio(fileURL:)` to feed it a sound file the way the real
///    mic tap would.
/// `BrownmellonApp` picks this on Simulator and `DATGlassesSession` on a
/// physical phone; no other code should need to know which is in use.
@MainActor
final class MockGlassesSession: NSObject, GlassesSession {
    private let synthesizer = AVSpeechSynthesizer()
    /// One continuation per in-flight utterance, keyed by the utterance the
    /// synthesizer hands back, so overlapping `speak` calls (a sound alert
    /// landing while a reminder is being read) each resume exactly once.
    private var speakContinuations: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
    private var photoPickerContinuation: CheckedContinuation<UIImage, Error>?
    private var onTranscript: ((String) -> Void)?
    private var audioTap: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private(set) var isListening = false

    /// Debug/demo hook — fires alongside real TTS so a screen with no
    /// speaker can show what the glasses just said (e.g. `SchedulingView`).
    var onSpeak: ((String) -> Void)?

    /// Test hook — when set, `capturePhoto()` returns this immediately
    /// instead of presenting the photo picker.
    var stubbedPhoto: UIImage?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Speak

    /// `synthesizer.isSpeaking`, but only while an utterance we started is
    /// still in flight: when Simulator audio is unavailable the synthesizer
    /// can report speaking forever (see `speak`), which would make features
    /// that mute the mic during speech deaf for the rest of the session.
    var isSpeaking: Bool { synthesizer.isSpeaking && !speakContinuations.isEmpty }

    func speak(_ text: String) async {
        onSpeak?(text)

        // The synthesizer never reports finishing an utterance it never
        // started; don't park a continuation on one.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

        // Simulator audio isn't always there (headless CI, a Mac with no output
        // device): the audio queue then fails to prime and the synthesizer never
        // reports finishing — or cancelling — the utterance. Hardware has no
        // such failure mode. A deadline well beyond real speaking time (~2.5
        // words/s) keeps callers from hanging without cutting healthy TTS short;
        // it does not stop the synthesizer, so audio that is merely slow plays on.
        let words = text.split(whereSeparator: \.isWhitespace).count
        let deadline = Duration.seconds(2.5 + 0.75 * Double(words))

        // Await completion so callers (e.g. SchedulingCoordinator resetting its
        // wake-word cooldown) don't run ahead of the audio — same as hardware.
        await withCheckedContinuation { continuation in
            speakContinuations[ObjectIdentifier(utterance)] = continuation
            synthesizer.speak(utterance)
            // Holds `utterance` so its identity can't be reused by a later one
            // before this deadline passes.
            Task { [weak self] in
                try? await Task.sleep(for: deadline)
                self?.finishSpeaking(utterance)
            }
        }
    }

    /// Idempotent: whichever of the delegate callback and the deadline comes
    /// first resumes the caller; the other finds nothing to do.
    private func finishSpeaking(_ utterance: AVSpeechUtterance) {
        speakContinuations.removeValue(forKey: ObjectIdentifier(utterance))?.resume()
    }

    // MARK: - Listen

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

    // MARK: - Audio tap

    func startAudioTap(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        audioTap = onBuffer
    }

    func stopAudioTap() {
        audioTap = nil
    }

    /// Test/demo hook — play a sound file into the installed audio tap as the
    /// real mic tap would: 4096-frame buffers in the file's processing
    /// format, delivered off the main actor. With `realtime` each buffer is
    /// followed by a pause of its own duration, so a 2-second clip takes
    /// 2 seconds; otherwise buffers arrive as fast as they can be read.
    /// No-op if no tap is installed.
    func simulateAudio(fileURL: URL, realtime: Bool = false) async throws {
        guard let tap = audioTap else { return }

        try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: fileURL)
            let format = file.processingFormat
            let frameCapacity: AVAudioFrameCount = 4096
            var sampleTime: AVAudioFramePosition = 0

            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
                    throw MockGlassesSessionError.audioBufferAllocationFailed
                }
                try file.read(into: buffer, frameCount: frameCapacity)
                guard buffer.frameLength > 0 else { break }

                tap(buffer, AVAudioTime(sampleTime: sampleTime, atRate: format.sampleRate))
                sampleTime += AVAudioFramePosition(buffer.frameLength)

                if realtime {
                    let seconds = Double(buffer.frameLength) / format.sampleRate
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
            }
        }.value
    }

    // MARK: - Photo

    func capturePhoto() async throws -> UIImage {
        if let stubbedPhoto {
            return stubbedPhoto
        }

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

// MARK: - AVSpeechSynthesizerDelegate

extension MockGlassesSession: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking(utterance) }
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
    case audioBufferAllocationFailed
}

private extension UIWindowScene {
    var keyWindow: UIWindow? {
        windows.first(where: \.isKeyWindow)
    }
}
