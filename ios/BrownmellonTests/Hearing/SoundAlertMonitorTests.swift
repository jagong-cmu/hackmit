import XCTest
import AVFoundation
import SoundAnalysis
@testable import Brownmellon

/// The detection path with real audio: the fixture clips go through Apple's
/// real classifier (`SNAudioFileAnalyzer` for the pure analysis checks,
/// `MockGlassesSession.simulateAudio` → `SoundAlertMonitor` for the full
/// path) and the glasses must say the product copy.
@MainActor
final class SoundAlertMonitorTests: XCTestCase {
    private var mock: MockGlassesSession!
    private var store: MockSecureLocalStore!
    private var notifier: SpyNotifier!

    override func setUp() async throws {
        try await super.setUp()
        mock = MockGlassesSession()
        store = MockSecureLocalStore()
        notifier = SpyNotifier()
    }

    private func makeMonitor(now: (() -> Date)? = nil) -> SoundAlertMonitor {
        SoundAlertMonitor(glasses: mock, store: store, notifier: notifier, now: now ?? Date.init)
    }

    // MARK: - Fixtures through the real analyzer

    /// Every classifier window for a clip, with the same window/overlap the
    /// monitor uses.
    private func classify(_ fixture: SoundFixture) throws -> [[SoundClassification]] {
        let url = try fixture.url
        let analyzer = try SNAudioFileAnalyzer(url: url)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTimeMakeWithSeconds(1.5, preferredTimescale: 48_000)
        request.overlapFactor = 0.5
        let observer = WindowCollector()
        try analyzer.add(request, withObserver: observer)
        analyzer.analyze()
        return observer.windows
    }

    /// Runs a clip's windows through a fresh decider with default settings.
    private func announcements(for fixture: SoundFixture, ambient: Bool = false) throws -> [SoundAlertAnnouncement] {
        var settings = SoundAlertSettings.default
        settings.setGroup(.ambient, enabled: ambient)
        let decider = SoundAlertDecider(settings: settings)
        var time = Date(timeIntervalSince1970: 1_700_000_000)
        return try classify(fixture).flatMap { window in
            defer { time = time.addingTimeInterval(0.75) }
            return decider.evaluate(window, isSpeaking: false, now: time).announcements
        }
    }

    private func peak(_ identifier: String, in windows: [[SoundClassification]]) -> Double {
        windows.compactMap { $0.first { $0.identifier == identifier }?.confidence }.max() ?? 0
    }

    func testSmokeAlarmFixtureIsDetected() throws {
        let windows = try classify(.smokeAlarm)
        XCTAssertGreaterThanOrEqual(windows.count, 2, "a 3 s clip yields three 1.5 s windows at 0.5 overlap")
        XCTAssertGreaterThanOrEqual(peak("smoke_detector", in: windows), 0.7)
        XCTAssertEqual(try announcements(for: .smokeAlarm).map(\.phrase), ["I hear a smoke alarm."])
    }

    func testDoorbellFixtureIsDetected() throws {
        let windows = try classify(.doorbell)
        XCTAssertGreaterThanOrEqual(peak("door_bell", in: windows), 0.7)
        XCTAssertEqual(
            try announcements(for: .doorbell).map(\.phrase),
            ["Someone's at the door — I heard the doorbell."]
        )
    }

    func testKnockFixtureIsDetected() throws {
        let windows = try classify(.knock)
        XCTAssertGreaterThanOrEqual(peak("knock", in: windows), 0.7)
        XCTAssertEqual(try announcements(for: .knock).map(\.phrase), ["I heard knocking."])
    }

    func testSilenceFixtureProducesNoAnnouncement() throws {
        let windows = try classify(.silence)
        XCTAssertFalse(windows.isEmpty)
        for identifier in SoundCatalog.identifiers {
            XCTAssertLessThan(peak(identifier, in: windows), 0.4, "\(identifier) should not register in a quiet room")
        }
        XCTAssertEqual(try announcements(for: .silence, ambient: true), [])
    }

    // MARK: - Full path: mock mic tap → analyzer → decider → glasses

    /// Plays a clip into the monitor's tap and returns everything the glasses
    /// said once `expectedCount` utterances arrived (or the timeout passed).
    private func play(
        _ fixture: SoundFixture,
        through monitor: SoundAlertMonitor,
        expecting expectedCount: Int,
        timeout: TimeInterval = 20
    ) async throws -> [String] {
        var spoken: [String] = []
        let done = expectation(description: "\(expectedCount) utterance(s)")
        done.assertForOverFulfill = false
        mock.onSpeak = { text in
            spoken.append(text)
            if spoken.count == expectedCount { done.fulfill() }
        }

        monitor.start()
        XCTAssertTrue(monitor.isRunning)
        let url = try fixture.url
        try await mock.simulateAudio(fileURL: url)

        await fulfillment(of: [done], timeout: timeout)
        return spoken
    }

    func testSmokeAlarmClipIsSpokenTwiceWithHapticAndNotification() async throws {
        let monitor = makeMonitor()

        let spoken = try await play(.smokeAlarm, through: monitor, expecting: 2)

        XCTAssertEqual(spoken, ["I hear a smoke alarm.", "I hear a smoke alarm."])
        XCTAssertEqual(monitor.lastAnnouncement, "I hear a smoke alarm.")
        XCTAssertEqual(notifier.safetyAlerts.map(\.soundName), ["Smoke alarm"], "Safety: haptic + notification, once")
        XCTAssertNil(monitor.lastError)
    }

    func testDoorbellClipIsSpokenOnceWithoutSafetyChannels() async throws {
        let monitor = makeMonitor()

        let spoken = try await play(.doorbell, through: monitor, expecting: 1)
        // Give a (wrong) repeat or second label a moment to show up.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertEqual(spoken, ["Someone's at the door — I heard the doorbell."])
        XCTAssertEqual(notifier.safetyAlerts, [], "only Safety sounds reach the phone")
    }

    func testKnockClipIsSpoken() async throws {
        let monitor = makeMonitor()

        let spoken = try await play(.knock, through: monitor, expecting: 1)

        XCTAssertEqual(spoken.first, "I heard knocking.")
    }

    func testSilenceClipProducesNoAnnouncement() async throws {
        let monitor = makeMonitor()
        var spoken: [String] = []
        mock.onSpeak = { spoken.append($0) }

        monitor.start()
        let url = try SoundFixture.silence.url
        try await mock.simulateAudio(fileURL: url)

        // Wait until the analyzer has delivered every window for the clip.
        let deadline = Date().addingTimeInterval(10)
        while monitor.processedWindowCount < 3, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertGreaterThanOrEqual(monitor.processedWindowCount, 3)
        XCTAssertEqual(spoken, [])
        XCTAssertNil(monitor.lastAnnouncement)
        XCTAssertEqual(notifier.safetyAlerts, [])
    }

    func testDoorbellClipIsRememberedForWhatWasThat() async throws {
        let monitor = makeMonitor()

        _ = try await play(.doorbell, through: monitor, expecting: 1)

        let notable = monitor.recentLog.mostNotable(now: Date())
        XCTAssertEqual(notable?.identifier, "door_bell")

        let replied = expectation(description: "answered what was that")
        var reply: String?
        mock.onSpeak = { text in
            reply = text
            replied.fulfill()
        }
        // Not awaited: `speak` waits for TTS to finish, and the assertion is
        // about what was sent, which `onSpeak` reports immediately.
        Task { _ = await monitor.handle("what was that") }

        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(reply, "Just now it sounded like a doorbell.")
    }

    // MARK: - Announce path without audio

    private func window(_ labels: (String, Double)...) -> SoundWindow {
        SoundWindow(classifications: labels.map { SoundClassification(identifier: $0.0, confidence: $0.1) }, streamTime: 0)
    }

    func testProcessedWindowsAnnounceAndLog() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var clock = t0
        let monitor = makeMonitor(now: { clock })
        var spoken: [String] = []
        let spoke = expectation(description: "announced")
        mock.onSpeak = { text in
            spoken.append(text)
            spoke.fulfill()
        }

        monitor.process(window(("door_bell", 0.9), ("door", 0.8)))
        clock = t0.addingTimeInterval(0.75)
        monitor.process(window(("door_bell", 0.95), ("door", 0.8)))

        await fulfillment(of: [spoke], timeout: 5)
        XCTAssertEqual(spoken, ["Someone's at the door — I heard the doorbell."])
        XCTAssertEqual(monitor.lastAnnouncement, "Someone's at the door — I heard the doorbell.")
        XCTAssertEqual(monitor.processedWindowCount, 2)
        XCTAssertEqual(
            monitor.recentLog.observations(now: clock).map(\.identifier),
            ["door_bell", "door_bell"],
            "catalog labels are logged; `door` is not in the catalog"
        )
        XCTAssertEqual(notifier.safetyAlerts, [])
    }

    func testSafetyWindowsReachThePhone() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var clock = t0
        let monitor = makeMonitor(now: { clock })

        monitor.process(window(("smoke_detector", 0.99)))
        clock = t0.addingTimeInterval(0.75)
        monitor.process(window(("smoke_detector", 0.99)))

        XCTAssertEqual(notifier.safetyAlerts, [SpyNotifier.Alert(soundName: "Smoke alarm", date: clock)])
        XCTAssertEqual(
            SystemSoundAlertNotifier.title(soundName: "Smoke alarm", at: clock),
            "Smoke alarm heard — \(clock.formatted(date: .omitted, time: .shortened))"
        )
    }

    // MARK: - Settings & lifecycle

    func testLoadsSavedSettingsAndStaysOffWhenDisabled() throws {
        var saved = SoundAlertSettings.default
        saved.isEnabled = false
        saved.setGroup(.ambient, enabled: true)
        try store.save(saved, forKey: SoundAlertSettings.storageKey)

        let monitor = makeMonitor()
        XCTAssertEqual(monitor.settings, saved)

        monitor.start()
        XCTAssertFalse(monitor.isRunning, "disabled in settings: no tap is installed")
    }

    func testUpdatePersistsAndTogglesTheTap() throws {
        let monitor = makeMonitor()
        monitor.start()
        XCTAssertTrue(monitor.isRunning)

        monitor.setEnabled(false)
        XCTAssertFalse(monitor.isRunning)
        let persisted: SoundAlertSettings? = try store.load(forKey: SoundAlertSettings.storageKey)
        XCTAssertEqual(persisted?.isEnabled, false)

        monitor.setGroup(.ambient, enabled: true)
        XCTAssertTrue(monitor.settings.enabledGroups.contains(.ambient))
        XCTAssertFalse(monitor.isRunning, "changing a group doesn't turn the master switch on")

        monitor.setEnabled(true)
        XCTAssertTrue(monitor.isRunning)
        let reloaded: SoundAlertSettings? = try store.load(forKey: SoundAlertSettings.storageKey)
        XCTAssertEqual(reloaded, monitor.settings)
    }

    func testStoppedMonitorIgnoresAudio() async throws {
        let monitor = makeMonitor()
        var spoken: [String] = []
        mock.onSpeak = { spoken.append($0) }

        monitor.start()
        monitor.stop()
        let url = try SoundFixture.smokeAlarm.url
        try await mock.simulateAudio(fileURL: url)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(monitor.processedWindowCount, 0)
        XCTAssertEqual(spoken, [])
    }

    func testNotificationPermissionGoesThroughTheNotifier() async {
        let monitor = makeMonitor()
        let before = await monitor.notificationAuthorizationStatus()
        XCTAssertEqual(before, .notDetermined)

        let granted = await monitor.requestNotificationPermission()

        XCTAssertTrue(granted)
        XCTAssertEqual(notifier.authorizationRequests, 1)
        let after = await monitor.notificationAuthorizationStatus()
        XCTAssertEqual(after, .authorized)
    }

    func testSettingsRoundTripThroughCodable() throws {
        var settings = SoundAlertSettings.default
        settings.setGroup(.ambient, enabled: true)
        settings.setGroup(.kitchen, enabled: false)
        settings.confidenceThreshold = 0.6

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SoundAlertSettings.self, from: data)

        XCTAssertEqual(decoded, settings)
        XCTAssertTrue(decoded.isEnabled(.ambient))
        XCTAssertFalse(decoded.isEnabled(.kitchen))
        XCTAssertTrue(decoded.isEnabled(.safety))
    }
}

/// Collects every classification window `SNAudioFileAnalyzer` produces.
private final class WindowCollector: NSObject, SNResultsObserving {
    private let lock = NSLock()
    private var collected: [[SoundClassification]] = []

    var windows: [[SoundClassification]] {
        lock.lock(); defer { lock.unlock() }
        return collected
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let window = result.classifications.map {
            SoundClassification(identifier: $0.identifier, confidence: $0.confidence)
        }
        lock.lock()
        collected.append(window)
        lock.unlock()
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {}
    func requestDidComplete(_ request: SNRequest) {}
}
