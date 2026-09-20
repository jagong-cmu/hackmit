import XCTest
@testable import Brownmellon

/// The handler chain is how every v2 feature receives voice commands, so
/// these pin down its contract: a handler that claims a command stops the
/// calendar intent parser from ever being called, one that declines falls
/// through, and the whole path from a simulated transcript through the
/// wake word to a handler works without a mic.
@MainActor
final class VoiceRoutingTests: XCTestCase {
    private var mock: MockGlassesSession!
    private var calendar: MockCalendarService!

    override func setUp() async throws {
        try await super.setUp()
        mock = MockGlassesSession()
        calendar = MockCalendarService()
        IntentEndpointStub.reset()
    }

    /// An `IntentClient` whose network layer is the stub: never touches the
    /// real backend, and records every request it does receive.
    private func stubbedIntentClient() -> IntentClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IntentEndpointStub.self]
        return IntentClient(
            endpoint: URL(string: "https://intent.test/api/parse-intent")!,
            session: URLSession(configuration: config)
        )
    }

    // MARK: - Short-circuit

    func testHandlerReturningTrueShortCircuitsIntentClient() async {
        let handler = SpyHandler(returning: true)
        let coordinator = SchedulingCoordinator(
            glasses: mock,
            calendar: calendar,
            intents: stubbedIntentClient(),
            handlers: [handler]
        )

        await coordinator.handle("test phrase")

        XCTAssertEqual(handler.received, ["test phrase"])
        XCTAssertEqual(IntentEndpointStub.hitCount, 0, "handler claimed the command; the intent backend must not be called")
    }

    // MARK: - Fall-through

    func testHandlerReturningFalseFallsThroughToNextHandler() async {
        let declining = SpyHandler(returning: false)
        let claiming = SpyHandler(returning: true)
        let coordinator = SchedulingCoordinator(
            glasses: mock,
            calendar: calendar,
            intents: stubbedIntentClient(),
            handlers: [declining, claiming]
        )

        await coordinator.handle("test phrase")

        XCTAssertEqual(declining.received, ["test phrase"])
        XCTAssertEqual(claiming.received, ["test phrase"])
        XCTAssertEqual(IntentEndpointStub.hitCount, 0)
    }

    func testHandlerReturningFalseFallsThroughToIntentClient() async {
        let declining = SpyHandler(returning: false)
        let coordinator = SchedulingCoordinator(
            glasses: mock,
            calendar: calendar,
            intents: stubbedIntentClient(),
            handlers: [declining]
        )

        let backendHit = expectation(description: "intent backend called")
        IntentEndpointStub.onHit = { backendHit.fulfill() }
        IntentEndpointStub.responseBody = Data(#"{"intent":"unknown","reason":""}"#.utf8)

        let spoken = expectation(description: "glasses spoke the unknown-intent reply")
        mock.onSpeak = { text in
            XCTAssertEqual(text, "Sorry, I didn't catch that.")
            spoken.fulfill()
        }

        // Not awaited: the coordinator's reply is real TTS, and the assertion is
        // about what it *sent*, which `onSpeak` reports before playback.
        Task { await coordinator.handle("test phrase") }

        await fulfillment(of: [backendHit, spoken], timeout: 5)
        XCTAssertEqual(declining.received, ["test phrase"])
        XCTAssertEqual(IntentEndpointStub.hitCount, 1)
        XCTAssertEqual(IntentEndpointStub.lastCommand, "test phrase")
    }

    // MARK: - Full path: transcript → wake word → coordinator → handler

    func testSimulatedTranscriptReachesHandlerThroughAssistant() async {
        let handler = SpyHandler(returning: true)
        let assistant = VoiceAssistant(
            glasses: mock,
            calendar: calendar,
            intents: stubbedIntentClient(),
            handlers: [handler]
        )
        let delivered = expectation(description: "handler received the command")
        handler.onHandle = { delivered.fulfill() }

        assistant.start()
        mock.simulateTranscript("hey dojo test phrase")

        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(handler.received, ["test phrase"], "wake word stripped, command normalized")
        XCTAssertEqual(IntentEndpointStub.hitCount, 0)
    }

    func testTranscriptWithoutWakeWordNeverReachesHandlers() async {
        let handler = SpyHandler(returning: true)
        let assistant = VoiceAssistant(
            glasses: mock,
            calendar: calendar,
            intents: stubbedIntentClient(),
            handlers: [handler]
        )
        assistant.start()

        mock.simulateTranscript("test phrase")
        // Give any (wrong) dispatch a chance to land before asserting.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(handler.received, [])
        XCTAssertEqual(IntentEndpointStub.hitCount, 0)
    }

    // MARK: - App-lifetime listening

    func testStartKeepsSessionListening() {
        let assistant = VoiceAssistant(
            glasses: mock,
            calendar: calendar,
            intents: stubbedIntentClient()
        )
        XCTAssertFalse(mock.isListening)
        XCTAssertFalse(assistant.isListening)

        assistant.start()

        XCTAssertTrue(mock.isListening, "the session must actually be asked to listen")
        XCTAssertTrue(assistant.isListening)
    }

    func testAssistantMirrorsSpokenResponses() async {
        let assistant = VoiceAssistant(
            glasses: mock,
            calendar: calendar,
            intents: stubbedIntentClient()
        )
        await mock.speak("")   // empty text is a no-op for TTS but still reports via onSpeak
        XCTAssertEqual(assistant.lastResponse, "")
    }

    func testAssistantChainsExistingOnSpeakHook() async {
        var seenByTest: [String] = []
        mock.onSpeak = { seenByTest.append($0) }

        let assistant = VoiceAssistant(
            glasses: mock,
            calendar: calendar,
            intents: stubbedIntentClient()
        )
        await mock.speak("")

        XCTAssertEqual(seenByTest, [""], "a hook installed before the assistant must keep firing")
        XCTAssertEqual(assistant.lastResponse, "")
    }

    // MARK: - One utterance per transcript

    /// A live recognizer appends every sentence to one growing transcript.
    /// After acting on a command the coordinator restarts listening so the
    /// next sentence starts from an empty transcript instead of arriving as
    /// "…parked in section b hey dojo what do i have today".
    func testActedOnCommandRestartsListening() async {
        let handler = SpyHandler(returning: true)
        let assistant = VoiceAssistant(
            glasses: mock,
            calendar: calendar,
            intents: stubbedIntentClient(),
            handlers: [handler]
        )
        let delivered = expectation(description: "handler received the command")
        handler.onHandle = { delivered.fulfill() }

        assistant.start()
        XCTAssertEqual(mock.startListeningCount, 1)

        mock.simulateTranscript("hey dojo test phrase")
        await fulfillment(of: [delivered], timeout: 5)
        // The restart happens as `handle` returns, after the handler ran.
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(mock.startListeningCount, 2, "listening restarts once per acted-on command")
        XCTAssertTrue(mock.isListening, "…and is live again afterwards")

        // A second command on the fresh transcript still reaches the handler.
        let deliveredAgain = expectation(description: "second command received")
        handler.onHandle = { deliveredAgain.fulfill() }
        mock.simulateTranscript("hey dojo second phrase")
        await fulfillment(of: [deliveredAgain], timeout: 5)
        XCTAssertEqual(handler.received, ["test phrase", "second phrase"])
    }

    func testTypedCommandWithoutStartDoesNotBeginListening() async {
        let handler = SpyHandler(returning: true)
        let assistant = VoiceAssistant(
            glasses: mock,
            calendar: calendar,
            intents: stubbedIntentClient(),
            handlers: [handler]
        )

        await assistant.handle("test phrase")

        XCTAssertEqual(handler.received, ["test phrase"])
        XCTAssertEqual(mock.startListeningCount, 0, "a restart only applies while listening is live")
        XCTAssertFalse(mock.isListening)
    }
}

// MARK: - Test doubles

/// Records every command it sees and answers with a fixed verdict.
@MainActor
private final class SpyHandler: VoiceCommandHandler {
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

/// Stands in for `api/parse-intent` at the URL-loading layer. Counts hits and
/// captures the last command sent, so a test can prove the backend was — or
/// was not — consulted without any network.
private final class IntentEndpointStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _hitCount = 0
    nonisolated(unsafe) private static var _lastCommand: String?
    nonisolated(unsafe) private static var _onHit: (@Sendable () -> Void)?
    nonisolated(unsafe) private static var _responseBody = Data(#"{"intent":"unknown","reason":""}"#.utf8)

    static var hitCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _hitCount
    }

    static var lastCommand: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastCommand
    }

    static var onHit: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onHit }
        set { lock.lock(); _onHit = newValue; lock.unlock() }
    }

    static var responseBody: Data {
        get { lock.lock(); defer { lock.unlock() }; return _responseBody }
        set { lock.lock(); _responseBody = newValue; lock.unlock() }
    }

    static func reset() {
        lock.lock()
        _hitCount = 0
        _lastCommand = nil
        _onHit = nil
        _responseBody = Data(#"{"intent":"unknown","reason":""}"#.utf8)
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let command = Self.commandFromBody(request)
        Self.lock.lock()
        Self._hitCount += 1
        Self._lastCommand = command
        let onHit = Self._onHit
        let body = Self._responseBody
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
        onHit?()
    }

    override func stopLoading() {}

    /// URLSession hands protocols the body as a stream, not `httpBody`.
    private static func commandFromBody(_ request: URLRequest) -> String? {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["command"] as? String
    }
}
