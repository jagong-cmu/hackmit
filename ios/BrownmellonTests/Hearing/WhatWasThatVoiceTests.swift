import XCTest
@testable import Brownmellon

/// "Hey Dojo, what was that?" end to end (PRD-sound-alerts § 8b): a simulated
/// transcript goes through `VoiceAssistant` → wake word → coordinator →
/// `SoundAlertMonitor` as a `VoiceCommandHandler`, and the glasses speak the
/// product copy. This is the proof the feature is voice-driven, not
/// button-driven.
@MainActor
final class WhatWasThatVoiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var mock: MockGlassesSession!
    private var store: MockSecureLocalStore!
    private var notifier: SpyNotifier!

    override func setUp() async throws {
        try await super.setUp()
        mock = MockGlassesSession()
        store = MockSecureLocalStore()
        notifier = SpyNotifier()
        QuietIntentEndpoint.reset()
    }

    private func makeMonitor() -> SoundAlertMonitor {
        SoundAlertMonitor(glasses: mock, store: store, notifier: notifier, now: { [now] in now })
    }

    private func makeAssistant(handlers: [VoiceCommandHandler]) -> VoiceAssistant {
        VoiceAssistant(
            glasses: mock,
            calendar: MockCalendarService(),
            intents: QuietIntentEndpoint.intentClient(),
            handlers: handlers
        )
    }

    /// Runs `transcript` through the full voice path and returns what the
    /// glasses were asked to say.
    private func speak(_ transcript: String, monitor: SoundAlertMonitor) async -> String? {
        let assistant = makeAssistant(handlers: [monitor])
        let spoken = expectation(description: "glasses spoke")
        var text: String?
        mock.onSpeak = { said in
            text = said
            spoken.fulfill()
        }

        assistant.start()
        mock.simulateTranscript(transcript)

        await fulfillment(of: [spoken], timeout: 5)
        return text
    }

    // MARK: - The required voice-path test

    func testHeyDojoWhatWasThatReportsADoorbellFromTenSecondsAgo() async {
        let monitor = makeMonitor()
        monitor.recentLog.record("door_bell", confidence: 0.9, at: now.addingTimeInterval(-10))

        let said = await speak("hey dojo what was that", monitor: monitor)

        XCTAssertEqual(said, "About ten seconds ago it sounded like a doorbell.")
        XCTAssertEqual(QuietIntentEndpoint.hitCount, 0, "the intent backend must not be consulted")
    }

    func testHeyDojoWhatWasThatWithNothingRecent() async {
        let monitor = makeMonitor()

        let said = await speak("hey dojo what was that", monitor: monitor)

        XCTAssertEqual(said, "I didn't notice anything unusual in the last minute.")
        XCTAssertEqual(QuietIntentEndpoint.hitCount, 0)
    }

    func testHeyDojoWhatWasThatOnlyRemembersTheLastMinute() async {
        let monitor = makeMonitor()
        monitor.recentLog.record("smoke_detector", confidence: 0.99, at: now.addingTimeInterval(-90))

        let said = await speak("hey dojo did you hear that", monitor: monitor)

        XCTAssertEqual(said, "I didn't notice anything unusual in the last minute.")
    }

    func testHeyDojoWhatWasThatWhenAlertsAreOff() async {
        var off = SoundAlertSettings.default
        off.isEnabled = false
        try? store.save(off, forKey: SoundAlertSettings.storageKey)
        let monitor = makeMonitor()
        monitor.recentLog.record("door_bell", confidence: 0.9, at: now.addingTimeInterval(-10))

        let said = await speak("hey dojo what was that noise", monitor: monitor)

        XCTAssertEqual(said, "Sound alerts are turned off. Your helper can turn them on in Setup.")
    }

    func testEveryClaimedPhraseWorksThroughTheWakeWord() async {
        for phrase in WhatWasThatResponder.claimedPhrases {
            mock = MockGlassesSession()
            let monitor = makeMonitor()
            monitor.recentLog.record("knock", confidence: 0.8, at: now.addingTimeInterval(-31))

            let said = await speak("hey dojo \(phrase)", monitor: monitor)

            XCTAssertEqual(said, "About thirty seconds ago it sounded like knocking.", phrase)
        }
        XCTAssertEqual(QuietIntentEndpoint.hitCount, 0)
    }

    func testUnrelatedCommandFallsThroughToTheNextHandler() async {
        let monitor = makeMonitor()
        var spoken: [String] = []
        mock.onSpeak = { spoken.append($0) }

        let handled = await monitor.handle("remind me to take my pills at nine")

        XCTAssertFalse(handled)
        XCTAssertEqual(spoken, [], "a declined command must not make the glasses speak")
    }

    func testUnrelatedCommandThroughTheAssistantReachesTheNextHandler() async {
        let monitor = makeMonitor()
        let next = RecordingHandler()
        let assistant = makeAssistant(handlers: [monitor, next])
        let delivered = expectation(description: "next handler got the command")
        next.onHandle = { delivered.fulfill() }

        assistant.start()
        mock.simulateTranscript("hey dojo what time is it")

        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(next.received, ["what time is it"])
    }

    // MARK: - Responder copy

    func testSpokenElapsedRoundsToFiveSecondsInWords() {
        XCTAssertEqual(WhatWasThatResponder.spokenElapsed(0), "Just now")
        XCTAssertEqual(WhatWasThatResponder.spokenElapsed(2.4), "Just now")
        XCTAssertEqual(WhatWasThatResponder.spokenElapsed(2.6), "About five seconds ago")
        XCTAssertEqual(WhatWasThatResponder.spokenElapsed(10.3), "About ten seconds ago")
        XCTAssertEqual(WhatWasThatResponder.spokenElapsed(13), "About fifteen seconds ago")
        XCTAssertEqual(WhatWasThatResponder.spokenElapsed(44), "About forty-five seconds ago")
        XCTAssertEqual(WhatWasThatResponder.spokenElapsed(58), "About a minute ago")
    }

    func testClaimsExactlyThePRDPhrases() {
        for phrase in ["what was that", "what was that sound", "what was that noise", "did you hear that", "what did you hear"] {
            XCTAssertTrue(WhatWasThatResponder.claims(phrase), phrase)
            XCTAssertTrue(WhatWasThatResponder.claims("um \(phrase) just now"), "embedded: \(phrase)")
        }
        // Other features' phrases must fall through untouched.
        for other in [
            "what time is it", "did you hear the news", "what was the weather", "",
            "remind me to take my pills at nine", "read this to me", "scan this", "scan this card", "check this ad",
            "can i eat this", "remember where i parked", "who is this",
        ] {
            XCTAssertFalse(WhatWasThatResponder.claims(other), other)
        }
    }

    func testReplyUsesTheCatalogDescription() {
        let smoke = RecentSoundObservation(identifier: "smoke_detector", confidence: 0.9, timestamp: now.addingTimeInterval(-20))
        XCTAssertEqual(
            WhatWasThatResponder.reply(isEnabled: true, observation: smoke, now: now),
            "About twenty seconds ago it sounded like a smoke alarm."
        )
        let unknown = RecentSoundObservation(identifier: "music", confidence: 0.9, timestamp: now)
        XCTAssertEqual(
            WhatWasThatResponder.reply(isEnabled: true, observation: unknown, now: now),
            WhatWasThatResponder.nothingReply,
            "labels outside the catalog are never described"
        )
    }
}

@MainActor
private final class RecordingHandler: VoiceCommandHandler {
    private(set) var received: [String] = []
    var onHandle: (() -> Void)?

    func handle(_ command: String) async -> Bool {
        received.append(command)
        onHandle?()
        return true
    }
}
