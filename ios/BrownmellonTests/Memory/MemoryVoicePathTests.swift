import XCTest
@testable import Brownmellon

/// The product is voice-first: "Hey Dojo, remember …" through the real
/// pipeline — `MockGlassesSession.simulateTranscript` → `WakeWordListener` →
/// `SchedulingCoordinator` → `MemoryCommandHandler` → `speak`. Only ASR is
/// missing. The calendar intent backend is a URL-loading stub that counts
/// hits, so a fall-through is provable and a wrongly claimed command is too.
@MainActor
final class MemoryVoicePathTests: XCTestCase {
    private var mock: MockGlassesSession!
    private var store: MemoryStore!
    private var signReader: StubSignReader!
    private var recall: StubRecallClient!
    private var location: StubLocationFixProvider!
    private var clock: TestClock!
    private var memory: MemoryCommandHandler!
    private var afterMemory: SpyHandler!
    private var assistant: VoiceAssistant!

    override func setUp() async throws {
        try await super.setUp()
        MemoryIntentEndpointStub.reset()

        mock = MockGlassesSession()
        store = MemoryStore(store: MockSecureLocalStore())
        signReader = StubSignReader()
        recall = StubRecallClient()
        location = StubLocationFixProvider()
        clock = TestClock()
        memory = MemoryCommandHandler(
            glasses: mock,
            store: store,
            vision: signReader,
            recall: recall,
            location: location,
            directions: SpyDirectionsOpener(),
            now: { [clock] in clock!.now }
        )
        // Sits behind the memory handler: anything it sees, memory declined.
        afterMemory = SpyHandler()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MemoryIntentEndpointStub.self]
        assistant = VoiceAssistant(
            glasses: mock,
            calendar: MockCalendarService(),
            intents: IntentClient(
                endpoint: URL(string: "https://intent.test/api/parse-intent")!,
                session: URLSession(configuration: config)
            ),
            handlers: [memory, afterMemory]
        )
        assistant.start()
    }

    /// Says `transcript` out loud (as far as the mock is concerned) and
    /// returns the first thing the glasses replied.
    private func hear(_ transcript: String) async -> String? {
        await firstSpokenLine(from: mock) { [mock] in
            mock!.simulateTranscript(transcript)
        }
    }

    // MARK: - Required by PRD-memory § Voice-path tests

    func testHeyDojoRememberSavesAParkingNoteAndConfirmsAloud() async {
        let line = await hear("hey dojo remember i parked in section b")

        XCTAssertEqual(line, "Got it. I'll remember: I parked in section B.")
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.kind, .parking)
        XCTAssertEqual(store.notes.first?.text, "i parked in section b")
        XCTAssertEqual(afterMemory.received, [], "memory claimed it; nothing fell through")
        XCTAssertEqual(MemoryIntentEndpointStub.hitCount, 0, "the calendar backend was never consulted")
    }

    func testHeyDojoWhereDidIParkSpeaksTheNoteBackWithJustNow() async throws {
        try store.add(MemoryNote(kind: .parking, text: "i parked in section b", createdAt: clock.now.addingTimeInterval(-5)))

        let line = await hear("hey dojo where did i park")

        XCTAssertEqual(line, "You told me just now: I parked in section B.")
        XCTAssertEqual(recall.hitCount, 0, "parking recall never touches the backend")
        XCTAssertEqual(MemoryIntentEndpointStub.hitCount, 0)
    }

    func testHeyDojoRemindMeFallsThroughToTheCalendarIntentPath() async {
        let backendHit = expectation(description: "intent backend called")
        MemoryIntentEndpointStub.onHit = { backendHit.fulfill() }

        mock.simulateTranscript("hey dojo remind me to take my pills at 8")

        await fulfillment(of: [backendHit], timeout: 5)
        XCTAssertEqual(afterMemory.received, ["remind me to take my pills at 8"], "the memory handler returned false")
        XCTAssertEqual(MemoryIntentEndpointStub.lastCommand, "remind me to take my pills at 8")
        XCTAssertTrue(store.notes.isEmpty, "nothing was saved as a note")
    }

    // MARK: - End to end: save, then ask

    func testSaveThenRecallInOneSession() async {
        let saved = await hear("hey dojo remember i parked in section b")
        XCTAssertEqual(saved, "Got it. I'll remember: I parked in section B.")

        // The mic is closed while the confirmation is spoken and reopened
        // afterwards; the follow-up waits for that, as a real one would.
        let listening = await mock.waitUntilListening()
        XCTAssertTrue(listening, "listening must resume after a command")
        clock.advance(by: 20)

        let recalled = await hear("hey dojo where did i park")
        XCTAssertEqual(recalled, "You told me just now: I parked in section B.")
        XCTAssertEqual(MemoryIntentEndpointStub.hitCount, 0)
    }

    func testPoliteSaveIsStillANote() async {
        let line = await hear("hey dojo please remember i parked in section b")

        XCTAssertEqual(line, "Got it. I'll remember: I parked in section B.")
        XCTAssertEqual(store.notes.first?.text, "i parked in section b", "the courtesy word is not part of the note")
        XCTAssertEqual(MemoryIntentEndpointStub.hitCount, 0, "politeness never sends a note to the calendar backend")
    }

    func testWakeWordVariantsStillReachMemory() async {
        // ASR rarely spells the made-up wake word right; the detector's job,
        // not ours — but the whole path has to hold up.
        let line = await hear("hey dodo remember frank is the new neighbor")

        XCTAssertEqual(line, "Got it. I'll remember: Frank is the new neighbor.")
        XCTAssertEqual(store.notes.first?.kind, .general)
    }

    func testGeneralRecallGoesToTheRecallBackendNotTheIntentBackend() async throws {
        try store.add(MemoryNote(kind: .general, text: "frank is the new neighbor", createdAt: clock.now.addingTimeInterval(-3600)))
        recall.result = .success(RecallAnswer(answer: "An hour ago you told me Frank is the new neighbor.", matchedNoteIds: []))

        let line = await hear("hey dojo what did i tell you about frank")

        XCTAssertEqual(line, "An hour ago you told me Frank is the new neighbor.")
        XCTAssertEqual(recall.hitCount, 1)
        XCTAssertEqual(MemoryIntentEndpointStub.hitCount, 0)
    }

    func testCalendarQuestionIsNotClaimedByMemory() async {
        let backendHit = expectation(description: "intent backend called")
        MemoryIntentEndpointStub.onHit = { backendHit.fulfill() }

        mock.simulateTranscript("hey dojo where is my next appointment")

        await fulfillment(of: [backendHit], timeout: 5)
        XCTAssertEqual(afterMemory.received, ["where is my next appointment"])
        XCTAssertEqual(recall.hitCount, 0)
    }
}

// MARK: - Test doubles

/// Records what reaches it — i.e. what the memory handler declined — and
/// declines too, so the calendar path still runs.
@MainActor
private final class SpyHandler: VoiceCommandHandler {
    private(set) var received: [String] = []

    func handle(_ command: String) async -> Bool {
        received.append(command)
        return false
    }
}

/// Stands in for `api/parse-intent` at the URL-loading layer (see
/// `VoiceRoutingTests` for the original). Counts hits and keeps the last
/// command so a test can prove the calendar backend was — or wasn't — asked.
private final class MemoryIntentEndpointStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _hitCount = 0
    nonisolated(unsafe) private static var _lastCommand: String?
    nonisolated(unsafe) private static var _onHit: (@Sendable () -> Void)?

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

    static func reset() {
        lock.lock()
        _hitCount = 0
        _lastCommand = nil
        _onHit = nil
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
        Self.lock.unlock()

        let body = Data(#"{"intent":"unknown","reason":""}"#.utf8)
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
