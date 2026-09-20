import XCTest
@testable import Brownmellon

/// The production handler chain — memory → food label → sound alerts →
/// calendar — with real handlers and stubbed backends. Pass-through spies sit
/// between the handlers so each utterance's owner is observable: the first
/// spy that did *not* see the command names the feature that claimed it.
@MainActor
final class CrossFeatureRoutingTests: XCTestCase {
    private enum Owner: String { case memory, food, sound, calendar }

    private var mock: MockGlassesSession!
    private var memory: MemoryCommandHandler!
    private var food: FoodLabelViewModel!
    private var sound: SoundAlertMonitor!
    private var assistant: VoiceAssistant!
    private var afterMemory: RecordingHandler!
    private var afterFood: RecordingHandler!
    private var afterSound: RecordingHandler!

    private static let table: [(String, Owner)] = [
        // Memory
        ("remember I parked in section B", .memory),
        ("where did I park?", .memory),
        ("where's my car keys", .memory),            // general recall, not the parking spot
        ("what did I tell you about Frank", .memory),
        ("forget it", .memory),                      // a calm "Okay.", nothing deleted
        ("please remember the car is in lot C", .memory),
        // Food label
        ("can I eat this?", .food),
        ("read the label", .food),
        ("please read the ingredients", .food),
        ("can you read this label", .food),
        ("how much sodium", .food),
        ("does this have peanuts", .food),
        // Sound alerts
        ("what was that?", .sound),
        ("did you hear that", .sound),
        ("um what was that noise", .sound),
        // Calendar, or a v1 feature that isn't voice-wired yet — never the v2 handlers
        ("remind me to take my pills at 8", .calendar),
        ("what do I have today", .calendar),
        ("where is my next appointment", .calendar),
        ("what was that appointment again", .calendar),
        ("what was that address I told you", .calendar),
        ("read this to me", .calendar),
        ("can I have this read to me", .calendar),
        ("scan this", .calendar),
        ("check this ad", .calendar),
        ("how do I make this appointment", .calendar),
        ("cancel my appointment", .calendar),
        ("cancel that", .calendar),                   // never a false "Okay." from memory
        ("read this label to me", .food),            // a polite tail on a food command stays food
    ]

    override func setUp() async throws {
        try await super.setUp()
        QuietIntentEndpoint.reset()

        mock = MockGlassesSession()
        mock.stubbedPhoto = FakeGlassesSession.blankPhoto()

        let clock = TestClock()
        memory = MemoryCommandHandler(
            glasses: mock,
            store: MemoryStore(store: MockSecureLocalStore()),
            vision: StubSignReader(),
            recall: StubRecallClient(),
            location: StubLocationFixProvider(),
            directions: SpyDirectionsOpener(),
            now: { [clock] in clock.now }
        )

        let dietStore = MockSecureLocalStore()
        try dietStore.save(DietaryProfile.lowSodiumPeanutAllergy, forKey: DietaryProfile.storageKey)
        food = FoodLabelViewModel(
            glasses: mock,
            store: dietStore,
            backend: StubFoodLabelBackend(try FoodLabelFixtures.soup())
        )

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        sound = SoundAlertMonitor(glasses: mock, store: MockSecureLocalStore(), notifier: SpyNotifier(), now: { now })

        afterMemory = RecordingHandler(returning: false)
        afterFood = RecordingHandler(returning: false)
        afterSound = RecordingHandler(returning: false)

        assistant = VoiceAssistant(
            glasses: mock,
            calendar: MockCalendarService(),
            intents: QuietIntentEndpoint.intentClient(),
            handlers: [memory, afterMemory, food, afterFood, sound, afterSound]
        )
    }

    private func owner(of utterance: String) async -> Owner {
        let memorySeen = afterMemory.received.count
        let foodSeen = afterFood.received.count
        let soundSeen = afterSound.received.count
        let calendarHits = QuietIntentEndpoint.hitCount

        // The typed path: same normalization and chain as speech, awaited.
        await assistant.handle(utterance)

        if afterMemory.received.count == memorySeen { return .memory }
        if afterFood.received.count == foodSeen { return .food }
        if afterSound.received.count == soundSeen { return .sound }
        XCTAssertEqual(QuietIntentEndpoint.hitCount, calendarHits + 1, "\(utterance): fell through, so the calendar backend must be consulted")
        return .calendar
    }

    func testEveryUtteranceReachesItsOwnerInProductionOrder() async {
        for (utterance, expected) in Self.table {
            let actual = await owner(of: utterance)
            XCTAssertEqual(actual, expected, "\"\(utterance)\" should be owned by \(expected.rawValue), was \(actual.rawValue)")
        }
    }

    /// Order independence: for each utterance exactly one of the three v2
    /// handlers claims it (none for calendar phrases), so swapping the chain
    /// order could never change who answers.
    func testClaimedSetsAreDisjoint() async {
        for (utterance, expected) in Self.table {
            let command = WakeWordDetector.normalize(utterance)
            var claims: [Owner] = []
            if await memory.handle(command) { claims.append(.memory) }
            if await food.handle(command) { claims.append(.food) }
            if await sound.handle(command) { claims.append(.sound) }

            switch expected {
            case .calendar:
                XCTAssertEqual(claims, [], "\"\(utterance)\" must be claimed by no v2 handler")
            default:
                XCTAssertEqual(claims, [expected], "\"\(utterance)\" must be claimed by exactly \(expected.rawValue)")
            }
        }
    }
}
