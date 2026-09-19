import Foundation
import UIKit
import GoogleSignIn

/// Real Google Calendar-backed CalendarService — shared foundation, see
/// PRD.md § Foundation ("needed by Workstream A (both features) and
/// Workstream B (appointment-card scanning writes an event)").
///
/// NOT usable yet. Two things are still missing, both one-time setup
/// tasks from PRD.md § Deployment, neither of which I can do from here:
///   1. A Google Cloud project + OAuth consent screen (Testing mode)
///   2. An iOS OAuth client ID from that project, wired into this app
///      (typically a `GoogleService-Info.plist` dropped into the Xcode
///      project, or the client ID registered directly — see
///      https://developers.google.com/identity/sign-in/ios/start-integrating)
/// Until both exist, `signIn` fails at runtime with a config error.
/// Keep using MockCalendarService until then.
///
/// Also: the GIDSignIn call signatures below are written from general
/// knowledge of the SDK, not verified against the actual resolved
/// package (SPM resolution needs full Xcode, not available when this
/// was written) — double-check against whatever GoogleSignIn-iOS
/// version actually resolves before trusting this compiles as-is.
@MainActor
final class GoogleCalendarService: CalendarService {
    private let scopes = ["https://www.googleapis.com/auth/calendar.events"]

    func createEvent(title: String, start: Date, end: Date?, location: String?) async throws -> CalendarEvent {
        let token = try await accessToken()
        let resolvedEnd = end ?? start.addingTimeInterval(60 * 60) // default 1hr if unspecified

        var body: [String: Any] = [
            "summary": title,
            "start": ["dateTime": iso8601(start)],
            "end": ["dateTime": iso8601(resolvedEnd)],
        ]
        if let location { body["location"] = location }

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkOK(response)

        let decoded = try JSONDecoder().decode(GoogleEvent.self, from: data)
        return CalendarEvent(id: decoded.id, title: decoded.summary ?? title, start: start, end: resolvedEnd, location: location)
    }

    func todaysEvents() async throws -> [CalendarEvent] {
        let token = try await accessToken()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: iso8601(startOfDay)),
            URLQueryItem(name: "timeMax", value: iso8601(endOfDay)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkOK(response)

        let decoded = try JSONDecoder().decode(GoogleEventList.self, from: data)
        return decoded.items.compactMap { $0.toCalendarEvent() }
    }

    // MARK: - Auth

    private func accessToken() async throws -> String {
        if let user = GIDSignIn.sharedInstance.currentUser {
            try await refreshIfNeeded(user)
            return user.accessToken.tokenString
        }

        guard let presenter = Self.topViewController() else {
            throw GoogleCalendarError.noPresenter
        }

        let user = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GIDGoogleUser, Error>) in
            GIDSignIn.sharedInstance.signIn(withPresenting: presenter, hint: nil, additionalScopes: scopes) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let user = result?.user {
                    continuation.resume(returning: user)
                } else {
                    continuation.resume(throwing: GoogleCalendarError.noPresenter)
                }
            }
        }
        return user.accessToken.tokenString
    }

    private func refreshIfNeeded(_ user: GIDGoogleUser) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            user.refreshTokensIfNeeded { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    private static func checkOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GoogleCalendarError.serverError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

enum GoogleCalendarError: Error {
    case noPresenter
    case serverError(Int)
}

// MARK: - Google Calendar API response shapes

private struct GoogleEvent: Codable {
    let id: String
    let summary: String?
}

private struct GoogleEventList: Codable {
    let items: [GoogleEventItem]
}

private struct GoogleEventItem: Codable {
    let id: String
    let summary: String?
    let location: String?
    let start: GoogleEventDateTime?
    let end: GoogleEventDateTime?

    func toCalendarEvent() -> CalendarEvent? {
        guard let startDate = start?.resolvedDate else { return nil }
        return CalendarEvent(id: id, title: summary ?? "Untitled", start: startDate, end: end?.resolvedDate, location: location)
    }
}

private struct GoogleEventDateTime: Codable {
    let dateTime: String?
    let date: String? // all-day events use this instead of dateTime

    var resolvedDate: Date? {
        if let dateTime { return ISO8601DateFormatter().date(from: dateTime) }
        if let date { return ISO8601DateFormatter().date(from: date + "T00:00:00Z") }
        return nil
    }
}
