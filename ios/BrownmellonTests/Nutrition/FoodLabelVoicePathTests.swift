import XCTest
@testable import Brownmellon

/// The product is voice-first: "Hey Dojo, can I eat this?" through
/// `VoiceAssistant` → `SchedulingCoordinator` → `FoodLabelViewModel`. These
/// drive the whole path with `MockGlassesSession.simulateTranscript` (the real
/// Simulator session, `stubbedPhoto` standing in for the camera) and assert on
/// what the glasses were asked to say — everything but ASR.
@MainActor
final class FoodLabelVoicePathTests: XCTestCase {
    private var mock: MockGlassesSession!
    private var glasses: CountingGlassesSession!
    private var store: MockSecureLocalStore!
    private var backend: StubFoodLabelBackend!
    private var foodLabel: FoodLabelViewModel!
    private var nextHandler: RecordingHandler!
    private var assistant: VoiceAssistant!
    private var spoken: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        mock = MockGlassesSession()
        mock.stubbedPhoto = FakeGlassesSession.blankPhoto()
        glasses = CountingGlassesSession(mock)

        store = MockSecureLocalStore()
        try store.save(DietaryProfile.lowSodiumPeanutAllergy, forKey: DietaryProfile.storageKey)

        backend = StubFoodLabelBackend(try FoodLabelFixtures.soup())
        foodLabel = FoodLabelViewModel(glasses: glasses, store: store, backend: backend)
        nextHandler = RecordingHandler(returning: true)

        spoken = []
        mock.onSpeak = { [weak self] text in self?.spoken.append(text) }

        // The intent backend must never be reached: `nextHandler` claims
        // anything the food handler declines, and the endpoint is unreachable
        // anyway — hitting it would make the coordinator speak an apology,
        // which the assertions below would catch.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        assistant = VoiceAssistant(
            glasses: mock,
            calendar: MockCalendarService(),
            intents: IntentClient(endpoint: URL(string: "https://intent.invalid/api/parse-intent")!, session: URLSession(configuration: config)),
            handlers: [foodLabel, nextHandler]
        )
        assistant.start()
    }

    /// Waits for the next thing the glasses are asked to say.
    private func nextSpoken(after count: Int, timeout: TimeInterval = 10) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while spoken.count <= count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard spoken.count > count else {
            throw VoicePathError.nothingSpoken(after: count)
        }
        return spoken[count]
    }

    private enum VoicePathError: Error {
        case nothingSpoken(after: Int)
    }

    // MARK: - PRD-required voice-path tests

    func testCanIEatThisSpeaksTheDoesNotFitScript() async throws {
        mock.simulateTranscript("hey dojo can i eat this")

        let text = try await nextSpoken(after: 0)
        XCTAssertTrue(text.contains("doesn't fit your low-sodium diet"), text)
        XCTAssertTrue(text.contains("two and a half servings"), text)
        XCTAssertTrue(text.hasPrefix("This is Campbell's Chicken Noodle Soup."), text)
        XCTAssertEqual(glasses.captureCount, 1, "one photo")
        XCTAssertEqual(backend.callCount, 1, "one backend call")
        XCTAssertEqual(nextHandler.received, [], "the food handler claimed it")
        XCTAssertEqual(foodLabel.lastAssessment?.verdict, .doesNotFit)
    }

    func testReadTheIngredientsRightAfterUsesTheCachedLabel() async throws {
        mock.simulateTranscript("hey dojo can i eat this")
        _ = try await nextSpoken(after: 0)
        XCTAssertEqual(glasses.captureCount, 1)

        // The mic is closed while the reply is spoken and reopened afterwards;
        // a real follow-up can only arrive once it is.
        let listening = await mock.waitUntilListening()
        XCTAssertTrue(listening, "listening must resume after a command")
        mock.simulateTranscript("hey dojo read the ingredients")

        let text = try await nextSpoken(after: 1)
        XCTAssertTrue(text.hasPrefix(FoodLabelSpeech.cachePrefix), text)
        XCTAssertTrue(text.contains("The ingredients are Chicken stock, "), text)
        XCTAssertTrue(text.contains("Water."), text)
        XCTAssertEqual(glasses.captureCount, 1, "no second photo")
        XCTAssertEqual(backend.callCount, 1, "no second backend call")
        XCTAssertEqual(nextHandler.received, [])
    }

    func testReadThisToMeIsLeftToFeatureFour() async throws {
        let direct = await foodLabel.handle("read this to me")
        XCTAssertFalse(direct, "Feature 4 keeps 'read this to me'")

        let delivered = expectation(description: "next handler received the command")
        nextHandler.onHandle = { delivered.fulfill() }
        mock.simulateTranscript("hey dojo read this to me")
        await fulfillment(of: [delivered], timeout: 5)

        XCTAssertEqual(nextHandler.received, ["read this to me"])
        XCTAssertEqual(glasses.captureCount, 0, "no photo taken")
        XCTAssertEqual(backend.callCount, 0)
        XCTAssertTrue(spoken.isEmpty, "the food handler said nothing")
    }

    func testCheckThisAdIsLeftToFeatureFive() async {
        let direct = await foodLabel.handle("check this ad")
        XCTAssertFalse(direct)
        XCTAssertEqual(glasses.captureCount, 0)
    }

    // MARK: - More of the voice surface

    func testReadThisLabelSpeaksTheHeadlineNotFullText() async throws {
        mock.simulateTranscript("hey dojo read this label")

        let text = try await nextSpoken(after: 0)
        XCTAssertTrue(text.hasPrefix("This is Campbell's Chicken Noodle Soup. One serving is 1 cup, and the package has about two and a half servings. Per serving: 60 calories, 890 milligrams of sodium"), text)
        XCTAssertTrue(text.hasSuffix(FoodLabelSpeech.offer), text)
        XCTAssertFalse(text.contains("39%"), "never the raw label text first")
        XCTAssertEqual(glasses.captureCount, 1)
    }

    func testHowMuchSodiumAnswersWithTheComparison() async throws {
        mock.simulateTranscript("hey dojo how much sodium")

        let text = try await nextSpoken(after: 0)
        XCTAssertEqual(text, "890 milligrams of sodium per serving — that's more than half of your daily limit.")
    }

    func testNotALabelAsksForTheNutritionPanel() async throws {
        backend.results = [try FoodLabelFixtures.notALabel()]
        mock.simulateTranscript("hey dojo can i eat this")

        let text = try await nextSpoken(after: 0)
        XCTAssertEqual(text, FoodLabelSpeech.notALabelScript)
    }

    func testWakeWordRequired() async throws {
        mock.simulateTranscript("can i eat this")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(glasses.captureCount, 0)
        XCTAssertTrue(spoken.isEmpty)
    }
}
