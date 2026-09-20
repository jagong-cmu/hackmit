import Foundation
import UIKit

/// The backend's answer to "where did I put my keys?" — `answer` is spoken
/// verbatim; `matchedNoteIds` says which notes it drew on.
struct RecallAnswer: Equatable {
    let answer: String
    let matchedNoteIds: [String]
}

enum RecallClientError: Error {
    case http(status: Int)
}

/// General recall goes through the backend; behind a protocol so the
/// handler's tests never hit the network.
@MainActor
protocol RecallAnswering: AnyObject {
    func answer(question: String, notes: [MemoryNote], now: Date, timeZone: TimeZone) async throws -> RecallAnswer
}

/// Calls `api/recall.ts` — same request/response style as `IntentClient`.
///
/// Privacy by construction: `Payload.Note` has no coordinate fields, so a
/// note's location cannot leave the phone through this client. The call is
/// stateless; the backend keeps nothing.
@MainActor
final class RecallClient: RecallAnswering {
    /// PRD-memory § 9b: the most recent 100 notes, newest first.
    static let maxNotes = 100

    let endpoint: URL
    private let session: URLSession

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func answer(question: String, notes: [MemoryNote], now: Date, timeZone: TimeZone) async throws -> RecallAnswer {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Self.payload(question: question, notes: notes, now: now, timeZone: timeZone)
        )

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RecallClientError.http(status: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(Body.self, from: data)
        return RecallAnswer(answer: decoded.answer, matchedNoteIds: decoded.matchedNoteIds ?? [])
    }

    // MARK: - Wire format

    /// Mirrors `RequestSchema` in api/recall.ts. Timestamps carry the
    /// wearer's UTC offset so the model can say "this morning at nine".
    struct Payload: Encodable, Equatable {
        struct Note: Encodable, Equatable {
            let id: String
            let kind: String
            let text: String
            let signText: String?
            let createdAt: String

            private enum CodingKeys: String, CodingKey {
                case id, kind, text, signText, createdAt
            }

            /// Explicit so `signText` is sent as `null`, never omitted — the
            /// backend schema is `nullable`, not optional.
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(id, forKey: .id)
                try container.encode(kind, forKey: .kind)
                try container.encode(text, forKey: .text)
                try container.encode(signText, forKey: .signText)
                try container.encode(createdAt, forKey: .createdAt)
            }
        }

        let question: String
        let now: String
        let timeZone: String
        let notes: [Note]
    }

    static func payload(question: String, notes: [MemoryNote], now: Date, timeZone: TimeZone) -> Payload {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone

        let recent = MemoryStore.newestFirst(notes).prefix(maxNotes)
        return Payload(
            question: question,
            now: formatter.string(from: now),
            timeZone: timeZone.identifier,
            notes: recent.map { note in
                Payload.Note(
                    id: note.id.uuidString,
                    kind: note.kind.rawValue,
                    text: note.text,
                    signText: note.hasSignText ? note.signText : nil,
                    createdAt: formatter.string(from: note.createdAt)
                )
            }
        )
    }

    private struct Body: Decodable {
        let answer: String
        let matchedNoteIds: [String]?
    }
}

// MARK: - Parking sign OCR

/// The one vision call this feature makes — reading the spot marker — behind
/// a protocol so tests can stub it. `VisionBackendClient` (api/ocr, mode
/// `read`) is the production implementation.
@MainActor
protocol ParkingSignReader {
    func readSignText(from image: UIImage) async throws -> String
}

extension VisionBackendClient: ParkingSignReader {
    func readSignText(from image: UIImage) async throws -> String {
        try await readAloud(image).text
    }
}
