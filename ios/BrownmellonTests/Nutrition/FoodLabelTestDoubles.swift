import Foundation
import UIKit
import AVFoundation
@testable import Brownmellon

/// Stands in for `api/food-label` — hands back fixtures in order (the last
/// one repeats) and records how it was called, so tests can prove a follow-up
/// made no backend call and the legibility retry used the larger size.
@MainActor
final class StubFoodLabelBackend: FoodLabelExtracting {
    var results: [FoodLabelResult]
    var error: Error?
    private(set) var callCount = 0
    private(set) var maxDimensions: [CGFloat] = []

    init(_ results: FoodLabelResult...) {
        self.results = results
    }

    func extract(_ image: UIImage, maxDimension: CGFloat) async throws -> FoodLabelResult {
        callCount += 1
        maxDimensions.append(maxDimension)
        if let error { throw error }
        precondition(!results.isEmpty, "StubFoodLabelBackend needs at least one result")
        return results.count > 1 ? results.removeFirst() : results[0]
    }
}

/// A `GlassesSession` whose `speak` returns immediately and records the text,
/// for view-model tests that don't need real TTS. The voice-path tests use
/// `MockGlassesSession` instead — the real Simulator session.
@MainActor
final class FakeGlassesSession: GlassesSession {
    private(set) var spoken: [String] = []
    private(set) var captureCount = 0
    var photo: UIImage = FakeGlassesSession.blankPhoto()
    var captureError: Error?
    var isSpeaking: Bool { false }

    func speak(_ text: String) async {
        spoken.append(text)
    }

    func startListening(onTranscript: @escaping (String) -> Void) {}
    func stopListening() {}

    func capturePhoto() async throws -> UIImage {
        captureCount += 1
        if let captureError { throw captureError }
        return photo
    }

    func startAudioTap(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {}
    func stopAudioTap() {}

    static func blankPhoto() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
    }
}

/// Wraps a `MockGlassesSession` so a test can count `capturePhoto` calls on
/// the real Simulator session while everything else passes straight through.
@MainActor
final class CountingGlassesSession: GlassesSession {
    let inner: MockGlassesSession
    private(set) var captureCount = 0

    init(_ inner: MockGlassesSession) {
        self.inner = inner
    }

    var isSpeaking: Bool { inner.isSpeaking }
    func speak(_ text: String) async { await inner.speak(text) }
    func startListening(onTranscript: @escaping (String) -> Void) { inner.startListening(onTranscript: onTranscript) }
    func stopListening() { inner.stopListening() }

    func capturePhoto() async throws -> UIImage {
        captureCount += 1
        return try await inner.capturePhoto()
    }

    func startAudioTap(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) { inner.startAudioTap(onBuffer) }
    func stopAudioTap() { inner.stopAudioTap() }
}

/// Records every command it sees and answers with a fixed verdict — placed
/// after the food-label handler to prove a command fell through.
@MainActor
final class RecordingHandler: VoiceCommandHandler {
    private(set) var received: [String] = []
    var onHandle: (() -> Void)?
    private let verdict: Bool

    init(returning verdict: Bool) {
        self.verdict = verdict
    }

    func handle(_ command: String) async -> Bool {
        received.append(command)
        onHandle?()
        return verdict
    }
}
