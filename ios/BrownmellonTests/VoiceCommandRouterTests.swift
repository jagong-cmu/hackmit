import XCTest
import UIKit
@testable import Brownmellon

/// End to end from a spoken transcript to a feature acting and the glasses
/// speaking, with a fake session standing in for the mic, speaker and camera.
/// The camera "fails" so no photo ever reaches the backend; what's under test
/// is that each command reaches the *right* feature and the tab follows.
@MainActor
final class VoiceCommandRouterTests: XCTestCase {
    private var glasses: FakeGlassesSession!
    private var emergency: EmergencyContactSetupViewModel!
    private var scanCard: AppointmentCardScanViewModel!
    private var readToMe: ReadToMeViewModel!
    private var adCheck: AdScamCheckViewModel!
    private var router: VoiceCommandRouter!

    override func setUp() {
        glasses = FakeGlassesSession()
        let calendar = MockCalendarService()
        // Nothing listens here, so scheduling commands fail fast and audibly —
        // which is exactly how we tell they were routed to the backend path.
        let intents = IntentClient(endpoint: URL(string: "http://127.0.0.1:1/api/parse-intent")!)
        scanCard = AppointmentCardScanViewModel(glasses: glasses, calendar: calendar)
        readToMe = ReadToMeViewModel(glasses: glasses)
        adCheck = AdScamCheckViewModel(glasses: glasses)
        emergency = EmergencyContactSetupViewModel(store: MockSecureLocalStore())
        router = VoiceCommandRouter(
            glasses: glasses,
            intents: intents,
            scheduling: SchedulingCoordinator(glasses: glasses, calendar: calendar, intents: intents),
            scanCard: scanCard,
            readToMe: readToMe,
            adCheck: adCheck,
            emergency: emergency,
            gate: VoiceTranscriptGate(settleDelay: 0.1, confirmationTimeout: 45)
        )
        router.startListening()
    }

    /// Speak a streaming utterance the way the recognizer delivers it, then
    /// wait for the router to settle it and the feature to finish talking.
    private func say(_ partials: String..., timeout: TimeInterval = 5) async {
        let spokenBefore = glasses.spoken.count
        for partial in partials { glasses.emit(partial) }
        let deadline = Date().addingTimeInterval(timeout)
        while glasses.spoken.count == spokenBefore, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // Let the router's post-speech bookkeeping run.
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func testListeningStartsWithTheRouter() {
        XCTAssertTrue(glasses.isListening)
        XCTAssertTrue(router.isListening)
    }

    func testScanThisReachesFeature3() async {
        await say("hey dojo scan", "hey dojo scan this")
        XCTAssertEqual(router.activeTab, .scanCard)
        XCTAssertEqual(router.lastCommand, "scan this")
        XCTAssertEqual(glasses.captures, 1)
        XCTAssertEqual(scanCard.state, .failed(String(describing: FakeGlassesSession.CameraError.unavailable)))
        XCTAssertEqual(glasses.spoken.last, "Something went wrong reading that card. Let's try again.")
    }

    func testReadThisReachesFeature4() async {
        await say("hey dojo read this to me")
        XCTAssertEqual(router.activeTab, .readToMe)
        XCTAssertEqual(glasses.captures, 1)
        XCTAssertEqual(readToMe.state, .failed(String(describing: FakeGlassesSession.CameraError.unavailable)))
    }

    func testCheckThisAdReachesFeature5() async {
        // The recognizer's usual spelling.
        await say("hey dojo check this add")
        XCTAssertEqual(router.activeTab, .checkAd)
        XCTAssertEqual(glasses.captures, 1)
        XCTAssertEqual(adCheck.state, .failed(String(describing: FakeGlassesSession.CameraError.unavailable)))
    }

    func testCall911ReachesFeature6WithoutTheBackend() async {
        await say("hey dojo call 911")
        XCTAssertEqual(router.activeTab, .setup)
        XCTAssertEqual(glasses.captures, 0)
        let said = glasses.spoken.last ?? ""
        // Simulator has no dialer; hardware opens the call sheet. Either way
        // the wearer is told what's happening and to confirm on the phone.
        XCTAssertTrue(said.contains("911"), said)
        XCTAssertTrue(said.contains("phone"), said)
    }

    func testCallMyDaughterDialsTheConfiguredContact() async {
        emergency.draftRelation = "Daughter"
        emergency.draftPhoneNumber = "555-0100"
        emergency.addContact()

        await say("hey dojo call my daughter")
        XCTAssertEqual(router.activeTab, .setup)
        let said = glasses.spoken.last ?? ""
        XCTAssertTrue(said.lowercased().contains("your daughter"), said)
        XCTAssertTrue(said.contains("phone"), said)
    }

    func testMostSpecificRelationWins() async {
        emergency.draftRelation = "son"
        emergency.draftPhoneNumber = "555-0101"
        emergency.addContact()
        emergency.draftRelation = "son in law"
        emergency.draftPhoneNumber = "555-0102"
        emergency.addContact()

        XCTAssertEqual(emergency.contact(matching: "son in law")?.phoneNumber, "555-0102")
        XCTAssertEqual(emergency.contact(matching: "son")?.phoneNumber, "555-0101")
        XCTAssertEqual(emergency.contact(matching: "Daughter"), nil)
    }

    func testCallUnknownRelationOffersWhatIsConfigured() async {
        emergency.draftRelation = "daughter"
        emergency.draftPhoneNumber = "555-0100"
        emergency.addContact()

        await say("hey dojo call my son")
        XCTAssertEqual(glasses.spoken.last, "I don't have a number for son. I can call your daughter, or 911.")
    }

    func testCallWithNoContactsExplainsSetup() async {
        await say("hey dojo call my daughter")
        XCTAssertEqual(glasses.spoken.last, "No emergency contacts are set up yet. Ask your caregiver to add one in Setup. I can always call 911.")
    }

    func testSchedulingGoesToTheBackend() async {
        await say("hey dojo remind me", "hey dojo remind me to take my pills at 8")
        XCTAssertEqual(router.activeTab, .schedule)
        XCTAssertEqual(router.lastCommand, "remind me to take my pills at 8")
        XCTAssertEqual(glasses.captures, 0)
        XCTAssertEqual(glasses.spoken.last, "Sorry, something went wrong. Please try again.")
    }

    func testTypedCommandRunsTheSamePath() async {
        await router.handle("scan this")
        XCTAssertEqual(router.activeTab, .scanCard)
        XCTAssertEqual(glasses.captures, 1)
    }

    func testYesWithNothingPendingIsHarmless() async {
        await say("hey dojo yes")
        XCTAssertEqual(glasses.captures, 0)
        XCTAssertEqual(glasses.spoken.last, "There's nothing to confirm right now.")
    }

    func testOneCommandAtATime() async {
        glasses.captureDelay = 0.5
        glasses.emit("hey dojo scan this")
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(router.isBusy)

        // A second command while the camera is busy is dropped, not queued…
        await router.handle("read this to me")
        XCTAssertEqual(glasses.captures, 1)
        XCTAssertEqual(router.lastResponse, "Still working on the last request…")

        // …unless it's an emergency.
        await router.handle("call 911")
        XCTAssertEqual(router.activeTab, .setup)
        XCTAssertTrue((glasses.spoken.last ?? "").contains("911"))
    }
}

/// Records what the app says, counts photo requests, and lets a test play
/// the recognizer. `capturePhoto` always fails so nothing reaches the network.
@MainActor
private final class FakeGlassesSession: GlassesSession {
    enum CameraError: Error { case unavailable }

    private(set) var spoken: [String] = []
    private(set) var captures = 0
    private(set) var isListening = false
    var captureDelay: TimeInterval = 0
    private var onTranscript: ((String) -> Void)?

    func speak(_ text: String) async { spoken.append(text) }

    func startListening(onTranscript: @escaping (String) -> Void) {
        self.onTranscript = onTranscript
        isListening = true
    }

    func stopListening() {
        onTranscript = nil
        isListening = false
    }

    func capturePhoto() async throws -> UIImage {
        captures += 1
        if captureDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(captureDelay * 1_000_000_000))
        }
        throw CameraError.unavailable
    }

    func emit(_ transcript: String) { onTranscript?(transcript) }
}
