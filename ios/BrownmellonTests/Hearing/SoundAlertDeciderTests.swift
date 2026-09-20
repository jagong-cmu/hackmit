import XCTest
@testable import Brownmellon

/// The decider rules from PRD-sound-alerts § 8a, each with a fake clock.
/// Windows arrive every 0.75 s (1.5 s window, 0.5 overlap), so "two
/// consecutive windows" is two calls 0.75 s apart.
final class SoundAlertDeciderTests: XCTestCase {
    private let hop: TimeInterval = 0.75
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private func window(_ labels: (String, Double)...) -> [SoundClassification] {
        labels.map { SoundClassification(identifier: $0.0, confidence: $0.1) }
    }

    private func settings(ambient: Bool = false, enabled: Bool = true) -> SoundAlertSettings {
        var settings = SoundAlertSettings.default
        settings.isEnabled = enabled
        settings.setGroup(.ambient, enabled: ambient)
        return settings
    }

    /// Feeds `count` consecutive windows of one label starting at `start`,
    /// returns every announcement made.
    @discardableResult
    private func detect(
        _ identifier: String,
        confidence: Double = 0.9,
        at start: TimeInterval,
        windows count: Int = 2,
        isSpeaking: Bool = false,
        with decider: SoundAlertDecider
    ) -> [SoundAlertAnnouncement] {
        (0..<count).flatMap { index in
            decider.evaluate(
                window((identifier, confidence)),
                isSpeaking: isSpeaking,
                now: at(start + Double(index) * hop)
            ).announcements
        }
    }

    // MARK: - PRD rule names

    func testAnnouncesAfterTwoConsecutiveWindowsAboveThreshold() {
        let decider = SoundAlertDecider(settings: settings())

        let first = decider.evaluate(window(("smoke_detector", 0.9)), isSpeaking: false, now: at(0))
        XCTAssertEqual(first.announcements, [], "one window is not enough")
        XCTAssertFalse(first.suppressed)

        let second = decider.evaluate(window(("smoke_detector", 0.9)), isSpeaking: false, now: at(hop))
        XCTAssertEqual(second.announcements.map(\.identifier), ["smoke_detector"])
        XCTAssertEqual(second.announcements.first?.phrase, "I hear a smoke alarm.")
    }

    func testDoesNotAnnounceOnSingleWindow() {
        let decider = SoundAlertDecider(settings: settings())

        // Above, below, above: never two in a row.
        var announced: [SoundAlertAnnouncement] = []
        announced += decider.evaluate(window(("door_bell", 0.95)), isSpeaking: false, now: at(0)).announcements
        announced += decider.evaluate(window(("door_bell", 0.3)), isSpeaking: false, now: at(hop)).announcements
        announced += decider.evaluate(window(("door_bell", 0.95)), isSpeaking: false, now: at(2 * hop)).announcements
        // A window without the label at all also breaks the streak.
        announced += decider.evaluate(window(("music", 0.8)), isSpeaking: false, now: at(3 * hop)).announcements
        announced += decider.evaluate(window(("door_bell", 0.95)), isSpeaking: false, now: at(4 * hop)).announcements

        XCTAssertEqual(announced, [])
    }

    func testRespectsPerLabelCooldown() {
        let decider = SoundAlertDecider(settings: settings())

        XCTAssertEqual(detect("smoke_detector", at: 0, with: decider).count, 1)
        XCTAssertEqual(detect("smoke_detector", at: 30, with: decider).count, 0, "+30 s is inside the 60 s cooldown")
        XCTAssertEqual(detect("smoke_detector", at: 61, with: decider).count, 1, "+61 s is past it")
    }

    func testSafetyLabelIgnoresAmbientCooldown() {
        let decider = SoundAlertDecider(settings: settings(ambient: true))

        XCTAssertEqual(detect("dog_bark", at: 0, with: decider).map(\.identifier), ["dog_bark"])
        XCTAssertEqual(
            detect("smoke_detector", at: 3, with: decider).map(\.identifier), ["smoke_detector"],
            "a smoke alarm right after a dog bark is still announced"
        )
    }

    func testSuppressesWhileSpeakingAndOneSecondAfter() {
        let decider = SoundAlertDecider(settings: settings())

        // Two strong windows while we're talking: dropped.
        let speaking1 = decider.evaluate(window(("smoke_detector", 0.99)), isSpeaking: true, now: at(0))
        let speaking2 = decider.evaluate(window(("smoke_detector", 0.99)), isSpeaking: true, now: at(hop))
        XCTAssertTrue(speaking1.suppressed)
        XCTAssertTrue(speaking2.suppressed)
        XCTAssertEqual(speaking1.announcements + speaking2.announcements, [])

        // 0.75 s after speech ended: still inside the 1 s guard.
        let tail = decider.evaluate(window(("smoke_detector", 0.99)), isSpeaking: false, now: at(2 * hop))
        XCTAssertTrue(tail.suppressed)
        XCTAssertEqual(tail.announcements, [])

        // 1.5 s after: counts again, and the streak starts from zero.
        let first = decider.evaluate(window(("smoke_detector", 0.99)), isSpeaking: false, now: at(3 * hop))
        XCTAssertFalse(first.suppressed)
        XCTAssertEqual(first.announcements, [], "windows dropped for speech don't count toward the streak")
        let second = decider.evaluate(window(("smoke_detector", 0.99)), isSpeaking: false, now: at(4 * hop))
        XCTAssertEqual(second.announcements.map(\.identifier), ["smoke_detector"])
    }

    func testDisabledLabelNeverAnnounces() {
        // Ambient is off by default.
        let ambientOff = SoundAlertDecider(settings: settings())
        XCTAssertEqual(detect("dog_bark", confidence: 0.99, at: 0, windows: 10, with: ambientOff), [])

        // Master switch off silences everything, Safety included.
        let allOff = SoundAlertDecider(settings: settings(enabled: false))
        XCTAssertEqual(detect("smoke_detector", confidence: 0.99, at: 0, windows: 10, with: allOff), [])
    }

    func testSpeechClassIsAlwaysIgnored() {
        let decider = SoundAlertDecider(settings: settings(ambient: true))
        XCTAssertEqual(detect("speech", confidence: 1.0, at: 0, windows: 20, with: decider), [])

        // Even a catalog that (wrongly) mapped speech to a phrase can't make it speak.
        let speechEntry = SoundCatalogEntry(
            identifier: "speech", group: .ambient,
            spokenPhrase: "I heard talking.", displayName: "Talking", description: "talking"
        )
        let withSpeech = SoundAlertDecider(settings: settings(ambient: true), catalog: SoundCatalog.entries + [speechEntry])
        XCTAssertEqual(detect("speech", confidence: 1.0, at: 0, windows: 20, with: withSpeech), [])
    }

    func testSafetyAnnouncementRepeatsOnce() {
        let decider = SoundAlertDecider(settings: settings())

        let smoke = detect("smoke_detector", at: 0, with: decider)
        XCTAssertEqual(smoke.count, 1)
        XCTAssertEqual(smoke.first?.repeatAfter, 2.0, "Safety: repeated once after 2 s")
        XCTAssertEqual(smoke.first?.repeatCount, 1)

        let doorbell = detect("door_bell", at: 100, with: decider)
        XCTAssertEqual(doorbell.count, 1)
        XCTAssertNil(doorbell.first?.repeatAfter, "only Safety repeats")
        XCTAssertEqual(doorbell.first?.repeatCount, 0)
    }

    // MARK: - Further contract

    func testContinuousAlarmIsAnnouncedOnceUntilSixtySecondsAfterItStops() {
        let decider = SoundAlertDecider(settings: settings())

        // Three minutes of a ringing smoke alarm, one window every 0.75 s.
        var announcements: [SoundAlertAnnouncement] = []
        var time: TimeInterval = 0
        while time <= 180 {
            announcements += decider.evaluate(window(("smoke_detector", 0.95)), isSpeaking: false, now: at(time)).announcements
            time += hop
        }
        XCTAssertEqual(announcements.count, 1, "one announcement (plus its repeat) for the whole alarm")

        // 30 s after it stopped: still quiet.
        XCTAssertEqual(detect("smoke_detector", at: 180 + 30, with: decider).count, 0)
        // 61 s after it stopped: a new alarm is announced again.
        XCTAssertEqual(detect("smoke_detector", at: 180 + 61, with: decider).count, 1)
    }

    func testStaleStreakDoesNotSurviveAGapInAudio() {
        let decider = SoundAlertDecider(settings: settings())

        // One strong window, then the audio stops for ten seconds (an
        // interruption, a recognizer restart) — that window must not pair up
        // with the first one after the gap.
        XCTAssertEqual(decider.evaluate(window(("smoke_detector", 0.9)), isSpeaking: false, now: at(0)).announcements, [])
        XCTAssertEqual(
            decider.evaluate(window(("smoke_detector", 0.9)), isSpeaking: false, now: at(10)).announcements, [],
            "a window from before the gap is not 'consecutive' with one after it"
        )
        // Back to back after the gap: announced as usual.
        XCTAssertEqual(
            decider.evaluate(window(("smoke_detector", 0.9)), isSpeaking: false, now: at(10 + hop)).announcements.map(\.identifier),
            ["smoke_detector"]
        )
    }

    func testOneSoundDoesNotAnnounceTwoLabels() {
        let decider = SoundAlertDecider(settings: settings())

        // A smoke alarm the classifier also half-hears as an alarm clock.
        let both = window(("smoke_detector", 0.9), ("alarm_clock", 0.8))
        var announced = decider.evaluate(both, isSpeaking: false, now: at(0)).announcements
        announced += decider.evaluate(both, isSpeaking: false, now: at(hop)).announcements
        announced += decider.evaluate(both, isSpeaking: false, now: at(2 * hop)).announcements

        XCTAssertEqual(announced.map(\.identifier), ["smoke_detector"], "highest priority wins; the other label is suppressed")
    }

    func testLowerPriorityLabelWaitsAfterAHigherPriorityAnnouncement() {
        let decider = SoundAlertDecider(settings: settings(ambient: true))

        XCTAssertEqual(detect("door_bell", at: 0, with: decider).count, 1)
        XCTAssertEqual(detect("dog_bark", at: 3, with: decider).count, 0, "inside the 10 s cross-label cooldown")
        XCTAssertEqual(detect("dog_bark", at: 15, with: decider).count, 1, "after it")
    }

    func testHigherPriorityLabelIsNotBlockedByALowerPriorityAnnouncement() {
        let decider = SoundAlertDecider(settings: settings(ambient: true))

        XCTAssertEqual(detect("dog_bark", at: 0, with: decider).count, 1)
        XCTAssertEqual(detect("telephone_bell_ringing", at: 3, with: decider).map(\.phrase), ["Your phone is ringing."])
    }

    func testThresholdIsASetting() {
        let strict = SoundAlertDecider(settings: settings())
        XCTAssertEqual(detect("door_bell", confidence: 0.65, at: 0, with: strict), [], "0.65 < default 0.7")

        var relaxed = settings()
        relaxed.confidenceThreshold = 0.5
        let lenient = SoundAlertDecider(settings: relaxed)
        XCTAssertEqual(detect("door_bell", confidence: 0.65, at: 0, with: lenient).count, 1)
    }

    func testRequiredWindowsIsASetting() {
        var three = settings()
        three.requiredConsecutiveWindows = 3
        let decider = SoundAlertDecider(settings: three)
        XCTAssertEqual(detect("knock", at: 0, windows: 2, with: decider), [])
        XCTAssertEqual(detect("knock", at: 2 * hop, windows: 1, with: decider).count, 1)
    }

    func testUnknownLabelsAreIgnored() {
        let decider = SoundAlertDecider(settings: settings(ambient: true))
        XCTAssertEqual(detect("music", confidence: 0.99, at: 0, windows: 10, with: decider), [])
        XCTAssertEqual(detect("door", confidence: 0.99, at: 0, windows: 10, with: decider), [])
    }
}
