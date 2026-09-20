import XCTest
import UserNotifications
@testable import Brownmellon

/// Records the redundant Safety channels instead of buzzing the phone or
/// posting real notifications from a test.
@MainActor
final class SpyNotifier: SoundAlertNotifying {
    struct Alert: Equatable {
        let soundName: String
        let date: Date
    }

    private(set) var safetyAlerts: [Alert] = []
    private(set) var authorizationRequests = 0
    var status: UNAuthorizationStatus = .notDetermined
    var grants = true

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        status = grants ? .authorized : .denied
        return grants
    }

    func safetyAlert(soundName: String, at date: Date) {
        safetyAlerts.append(Alert(soundName: soundName, date: date))
    }
}

/// The intent backend must never be consulted for a command this feature
/// owns. Stands in for `api/parse-intent` at the URL-loading layer, counting
/// every hit; tests assert zero.
final class QuietIntentEndpoint: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _hitCount = 0

    static var hitCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _hitCount
    }

    static func reset() {
        lock.lock()
        _hitCount = 0
        lock.unlock()
    }

    /// An `IntentClient` wired to this stub.
    static func intentClient() -> IntentClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QuietIntentEndpoint.self]
        return IntentClient(
            endpoint: URL(string: "https://intent.test/api/parse-intent")!,
            session: URLSession(configuration: config)
        )
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._hitCount += 1
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"intent":"unknown","reason":""}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The WAV clips under BrownmellonTests/Fixtures/Sounds (see SOURCES.txt).
enum SoundFixture: String, CaseIterable {
    case smokeAlarm = "smoke_alarm"
    case doorbell
    case knock
    case silence

    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String { "fixture \(name).wav is not in the test bundle — check project.yml picks up BrownmellonTests/Fixtures/Sounds" }
    }

    /// Fails the test (rather than skipping it) when the clip isn't bundled:
    /// these fixtures are the success criteria.
    var url: URL {
        get throws {
            guard let url = Bundle(for: SpyNotifier.self).url(forResource: rawValue, withExtension: "wav") else {
                throw Missing(name: rawValue)
            }
            return url
        }
    }
}
