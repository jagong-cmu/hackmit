import Foundation

/// What the wearer asked for, once the backend has parsed it.
enum VoiceIntent: Equatable {
    case createEvent(title: String, start: Date, end: Date?)
    case dailyBriefing
    /// Features 3–6. The phone classifies the common phrasings for these
    /// itself (`VoiceCommandClassifier`) before ever calling the backend; the
    /// model returns them for paraphrases that list misses ("what does this
    /// letter say", "is this offer for real").
    case scanCard
    case readText
    case checkAd
    case callEmergency
    /// `contact` is whoever the wearer named ("daughter"), for the phone to
    /// match against its configured emergency contacts.
    case callContact(String)
    /// Not something we can act on, or too ambiguous. `reason` is written
    /// to be spoken aloud.
    case unknown(reason: String)
}

enum IntentClientError: Error {
    case http(status: Int)
    case malformedResponse(String)
}

/// Calls `api/parse-intent.ts` to turn a spoken command into a `VoiceIntent`.
///
/// The phone sends the current time and time zone with every request — the
/// backend is stateless, and "tomorrow at two" is meaningless without them.
struct IntentClient {
    let endpoint: URL
    var session: URLSession = .shared

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func parse(
        command: String,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) async throws -> VoiceIntent {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Payload(
                command: command,
                now: Self.iso.string(from: now),
                timeZone: timeZone.identifier
            )
        )

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw IntentClientError.http(status: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(Body.self, from: data)

        switch decoded.intent {
        case "create_event":
            guard let title = decoded.title, !title.isEmpty,
                  let startString = decoded.start,
                  let start = Self.iso.date(from: startString)
            else {
                throw IntentClientError.malformedResponse("create_event missing title or start")
            }
            let end = decoded.end.flatMap(Self.iso.date(from:))
            return .createEvent(title: title, start: start, end: end)

        case "daily_briefing":
            return .dailyBriefing

        case "scan_card":
            return .scanCard

        case "read_text":
            return .readText

        case "check_ad":
            return .checkAd

        case "call_emergency":
            return .callEmergency

        case "call_contact":
            guard let contact = decoded.contact?.trimmingCharacters(in: .whitespacesAndNewlines), !contact.isEmpty else {
                throw IntentClientError.malformedResponse("call_contact missing contact")
            }
            return .callContact(contact.lowercased())

        case "unknown":
            return .unknown(reason: decoded.reason ?? "")

        default:
            throw IntentClientError.malformedResponse("unrecognized intent: \(decoded.intent)")
        }
    }

    private struct Payload: Encodable {
        let command: String
        let now: String
        let timeZone: String
    }

    private struct Body: Decodable {
        let intent: String
        let title: String?
        let start: String?
        let end: String?
        let contact: String?
        let reason: String?
    }
}
