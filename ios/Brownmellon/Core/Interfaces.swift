import Foundation
import UIKit

// Shared foundation interfaces (see PRD.md § Parallel workstreams).
// Owned collectively across all three workstreams — code against these
// plus the Mock implementations in Core/Mocks/.

@MainActor
protocol GlassesSession {
    /// Speaks text aloud through the glasses' open-ear speaker.
    func speak(_ text: String) async

    /// Starts streaming mic audio and calling `onTranscript` with
    /// recognized speech. Used by the wake-word/keyword pipeline.
    func startListening(onTranscript: @escaping (String) -> Void)

    func stopListening()

    /// Captures a single still photo via the glasses camera (episodic,
    /// not continuous streaming — see PRD design principles).
    func capturePhoto() async throws -> UIImage
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
