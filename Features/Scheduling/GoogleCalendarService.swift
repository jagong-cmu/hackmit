import Foundation

/// Google Calendar v3 implementation of `CalendarService`.
///
/// Workstream A owns this file; per the PRD it is the shared implementation
/// Workstream B consumes through the protocol for appointment-card scanning.
///
/// Auth is injected rather than built in: `accessToken` returns a currently
/// valid OAuth access token. Keeping the token flow outside this type means the
/// calendar calls are testable without standing up OAuth, and whoever wires up
/// Google Sign-In can do it without touching this file.
struct GoogleCalendarService: CalendarService {
    typealias AccessTokenProvider = () async throws -> String

    enum ServiceError: Error {
        case http(status: Int, body: String)
    }

    private let accessToken: AccessTokenProvider
    private let calendarID: String
    private let session: URLSession
    private let base = URL(string: "https://www.googleapis.com/calendar/v3")!

    /// Google returns RFC 3339 timestamps, sometimes with fractional seconds.
    private static let parsers: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [plain, withFraction]
    }()

    private static let writer: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init(
        calendarID: String = "primary",
        session: URLSession = .shared,
        accessToken: @escaping AccessTokenProvider
    ) {
        self.calendarID = calendarID
        self.session = session
        self.accessToken = accessToken
    }

    func createEvent(title: String, start: Date, end: Date?) async throws {
        // A reminder spoken without an end time still needs one on the wire.
        let resolvedEnd = end ?? start.addingTimeInterval(3600)

        let body = NewEvent(
            summary: title,
            start: .init(dateTime: Self.writer.string(from: start), timeZone: TimeZone.current.identifier),
            end: .init(dateTime: Self.writer.string(from: resolvedEnd), timeZone: TimeZone.current.identifier)
        )

        var request = try await authorized(path: "calendars/\(calendarID)/events")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        _ = try await send(request)
    }

    func todaysEvents() async throws -> [CalendarEvent] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return []
        }

        var components = URLComponents(
            url: base.appendingPathComponent("calendars/\(calendarID)/events"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            .init(name: "timeMin", value: Self.writer.string(from: startOfDay)),
            .init(name: "timeMax", value: Self.writer.string(from: endOfDay)),
            // Expand recurring events, so a weekly appointment shows up today.
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
        ]
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")

        let data = try await send(request)
        let list = try JSONDecoder().decode(EventList.self, from: data)

        return list.items.compactMap { item in
            guard let start = item.start?.resolvedDate else { return nil }
            return CalendarEvent(
                id: item.id,
                title: item.summary ?? "Untitled",
                start: start,
                end: item.end?.resolvedDate
            )
        }
    }

    // MARK: - Plumbing

    private func authorized(path: String) async throws -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ServiceError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }

    private static func parse(_ string: String) -> Date? {
        for parser in parsers {
            if let date = parser.date(from: string) { return date }
        }
        return nil
    }

    // MARK: - Wire types

    private struct NewEvent: Encodable {
        struct Stamp: Encodable {
            let dateTime: String
            let timeZone: String
        }
        let summary: String
        let start: Stamp
        let end: Stamp
    }

    private struct EventList: Decodable {
        let items: [Item]
    }

    private struct Item: Decodable {
        let id: String
        let summary: String?
        let start: Stamp?
        let end: Stamp?
    }

    /// Google sends `dateTime` for timed events and `date` for all-day ones.
    private struct Stamp: Decodable {
        let dateTime: String?
        let date: String?

        var resolvedDate: Date? {
            if let dateTime { return GoogleCalendarService.parse(dateTime) }
            guard let date else { return nil }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = .current
            return formatter.date(from: date)
        }
    }
}
