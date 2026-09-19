import Foundation
import UIKit

/// A single calendar entry, in the shape every workstream reads and writes.
struct CalendarEvent: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var start: Date
    var end: Date?

    init(id: String = UUID().uuidString, title: String, start: Date, end: Date? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
    }
}

/// One live connection to the glasses: mic in, speaker out, camera capture.
///
/// Deliberately a single object rather than three — underneath it is one DAT
/// session, and splitting it across owners would mean fighting over the same
/// connection.
protocol GlassesSession: AnyObject {
    func speak(_ text: String) async
    func startListening(onTranscript: @escaping (String) -> Void)
    func stopListening()
    func capturePhoto() async throws -> UIImage
}

protocol CalendarService {
    func createEvent(title: String, start: Date, end: Date?) async throws
    func todaysEvents() async throws -> [CalendarEvent]
}

protocol SecureLocalStore {
    func save<T: Codable>(_ value: T, forKey: String) throws
    func load<T: Codable>(forKey: String) throws -> T?
}
