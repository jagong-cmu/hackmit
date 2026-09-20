import Foundation
import UIKit
import AVFoundation

// Shared foundation interfaces (see PRD.md § Parallel workstreams).
// Owned collectively across all three workstreams — code against these
// plus the Mock implementations in Core/Mocks/.

@MainActor
protocol GlassesSession {
    /// Speaks text aloud through the glasses' open-ear speaker. Returns once
    /// the audio has finished playing.
    func speak(_ text: String) async

    /// Starts streaming mic audio and calling `onTranscript` with
    /// recognized speech. Used by the wake-word/keyword pipeline.
    func startListening(onTranscript: @escaping (String) -> Void)

    func stopListening()

    /// Captures a single still photo via the glasses camera (episodic,
    /// not continuous streaming — see PRD design principles).
    func capturePhoto() async throws -> UIImage

    /// True while the glasses speaker is playing our own speech. Features
    /// use this to ignore the mic while we talk (the open-ear speaker leaks
    /// straight back into the mic array).
    var isSpeaking: Bool { get }

    /// Raw mic audio for on-device analysis (sound classification). Runs
    /// alongside `startListening` — both are consumers of the same input
    /// stream. Buffers never leave the device. The callback arrives on the
    /// audio thread, not the main actor.
    func startAudioTap(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)
    func stopAudioTap()
}

struct CalendarEvent: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var start: Date
    var end: Date?
    var location: String?
}

protocol CalendarService {
    /// Every write requires the caller to have already gotten spoken
    /// confirmation from the wearer — this protocol does not enforce
    /// that, the feature code does (see PRD design principles).
    @discardableResult
    func createEvent(title: String, start: Date, end: Date?, location: String?) async throws -> CalendarEvent

    /// Today's events, **sorted by start time ascending** — callers speak
    /// these aloud in order and do not re-sort.
    func todaysEvents() async throws -> [CalendarEvent]
}

protocol SecureLocalStore {
    func save<T: Codable>(_ value: T, forKey: String) throws
    func load<T: Codable>(forKey: String) throws -> T?
}
