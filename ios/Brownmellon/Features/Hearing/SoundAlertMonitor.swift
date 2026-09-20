import Foundation
import AVFoundation
import Combine
import UserNotifications

/// Feature 8 end to end: consumes the glasses' mic tap, runs the on-device
/// classifier, asks `SoundAlertDecider` whether to speak, and speaks — plus
/// haptic and notification for Safety sounds. Also the `VoiceCommandHandler`
/// for "what was that?" (see `WhatWasThatHandler.swift`) and the Setup
/// screen's view model (settings persist through `SecureLocalStore`).
///
/// Lifecycle is owned by `BrownmellonApp`: created once as a plain property,
/// `start()`ed from the root view's `.task`, never tied to a tab. It runs on
/// hardware and Simulator alike — on Simulator the input is
/// `MockGlassesSession.simulateAudio(fileURL:)`.
///
/// Nothing here records or uploads audio, and nothing makes a network call.
@MainActor
final class SoundAlertMonitor: ObservableObject {
    @Published private(set) var settings: SoundAlertSettings
    /// True while an audio tap is installed and being analyzed.
    @Published private(set) var isRunning = false
    /// The last phrase spoken because of a detected sound.
    @Published private(set) var lastAnnouncement: String?
    @Published private(set) var lastError: String?
    /// Classifier windows seen so far — diagnostics and tests. Deliberately
    /// not published: it ticks every 0.75 s and nothing on screen needs it.
    private(set) var processedWindowCount = 0

    let recentLog: RecentSoundLog
    let glasses: GlassesSession
    let now: () -> Date

    private let store: SecureLocalStore
    private let notifier: SoundAlertNotifying
    private let decider: SoundAlertDecider
    private var classifier: SoundStreamClassifier?
    /// In-flight speech (and pending Safety repeats), so `stop()` can cancel
    /// them. Each task removes itself when it finishes.
    private var announcementTasks: [UUID: Task<Void, Never>] = [:]

    /// `notifier` defaults to the real haptic + `UNUserNotificationCenter`
    /// channels; tests pass a spy.
    init(
        glasses: GlassesSession,
        store: SecureLocalStore,
        notifier: SoundAlertNotifying? = nil,
        deciderConfiguration: SoundAlertDecider.Configuration = SoundAlertDecider.Configuration(),
        recentLog: RecentSoundLog = RecentSoundLog(),
        now: @escaping () -> Date = Date.init
    ) {
        self.glasses = glasses
        self.store = store
        self.notifier = notifier ?? SystemSoundAlertNotifier()
        self.recentLog = recentLog
        self.now = now

        var loaded = SoundAlertSettings.default
        do {
            if let saved: SoundAlertSettings = try store.load(forKey: SoundAlertSettings.storageKey) {
                loaded = saved
            }
        } catch {
            lastError = "Couldn't load sound alert settings; using defaults."
        }
        settings = loaded
        decider = SoundAlertDecider(settings: loaded, configuration: deciderConfiguration)
    }

    // MARK: - Lifecycle

    /// Whether iOS has refused the mic. The wake-word path asks for it; if it
    /// was denied the Setup screen says so and this feature stays off.
    var isMicrophoneDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }

    /// Installs the audio tap when settings say enabled. Idempotent.
    func start() {
        guard settings.isEnabled, !isRunning else { return }
        guard !isMicrophoneDenied else {
            lastError = "Microphone access is off, so sound alerts can't run. Enable it in Settings → Brownmellon."
            return
        }
        lastError = nil

        let classifier = SoundStreamClassifier(
            onError: { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.lastError = "Sound analysis failed: \(error.localizedDescription)"
                }
            },
            onWindow: { [weak self] window in
                Task { @MainActor [weak self] in self?.process(window) }
            }
        )
        self.classifier = classifier
        // The tap closure runs on the audio thread: it touches only the
        // classifier, which hops to its own serial queue.
        glasses.startAudioTap { buffer, when in
            classifier.analyze(buffer, at: when)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        glasses.stopAudioTap()
        classifier?.finish()
        classifier = nil
        // A pending Safety repeat shouldn't play after the caregiver turned
        // alerts off; speech already in flight finishes on its own.
        announcementTasks.values.forEach { $0.cancel() }
        announcementTasks.removeAll()
        isRunning = false
    }

    // MARK: - Settings (Setup screen)

    func update(_ newSettings: SoundAlertSettings) {
        settings = newSettings
        decider.settings = newSettings
        do {
            try store.save(newSettings, forKey: SoundAlertSettings.storageKey)
        } catch {
            lastError = "Couldn't save sound alert settings."
        }
        if newSettings.isEnabled {
            start()
        } else {
            stop()
        }
    }

    func setEnabled(_ enabled: Bool) {
        var next = settings
        next.isEnabled = enabled
        update(next)
    }

    func setGroup(_ group: SoundGroup, enabled: Bool) {
        var next = settings
        next.setGroup(group, enabled: enabled)
        update(next)
    }

    func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await notifier.authorizationStatus()
    }

    /// Called by Setup when alerts are first enabled — never at launch.
    @discardableResult
    func requestNotificationPermission() async -> Bool {
        await notifier.requestAuthorization()
    }

    // MARK: - Detection

    /// One classifier window in; zero or more spoken alerts out. Called on the
    /// main actor for every window (~every 0.75 s). Tests feed windows here
    /// directly to exercise the announce path without audio.
    func process(_ window: SoundWindow) {
        let now = self.now()
        processedWindowCount += 1

        let outcome = decider.evaluate(window.classifications, isSpeaking: glasses.isSpeaking, now: now)
        guard !outcome.suppressed else { return }

        for classification in window.classifications
        where SoundCatalog.entry(for: classification.identifier) != nil {
            recentLog.record(classification.identifier, confidence: classification.confidence, at: now)
        }

        for announcement in outcome.announcements {
            announce(announcement, at: now)
        }
    }

    private func announce(_ announcement: SoundAlertAnnouncement, at date: Date) {
        lastAnnouncement = announcement.phrase
        if announcement.group == .safety {
            notifier.safetyAlert(soundName: announcement.entry.displayName, at: date)
        }

        let glasses = glasses
        let id = UUID()
        // Scheduled on the main actor, so it can't run before it's registered below.
        announcementTasks[id] = Task { @MainActor [weak self] in
            defer { self?.announcementTasks[id] = nil }
            await glasses.speak(announcement.phrase)
            if let delay = announcement.repeatAfter {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await glasses.speak(announcement.phrase)
            }
        }
    }

    #if targetEnvironment(simulator)
    /// Simulator demo (PRD § Simulator / demo): plays a bundled clip into the
    /// mock's audio tap in real time, as if the glasses' mic heard it.
    enum DemoSound: String, CaseIterable, Identifiable {
        case smokeAlarm = "smoke_alarm"
        case doorbell
        case knock
        case silence

        var id: String { rawValue }
        var title: String {
            switch self {
            case .smokeAlarm: return "smoke alarm"
            case .doorbell: return "doorbell"
            case .knock: return "knock"
            case .silence: return "silence"
            }
        }
    }

    func playDemo(_ sound: DemoSound) async {
        guard let mock = glasses as? MockGlassesSession else { return }
        guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "wav") else {
            lastError = "Demo clip \(sound.rawValue).wav isn't in the app bundle."
            return
        }
        do {
            try await mock.simulateAudio(fileURL: url, realtime: true)
        } catch {
            lastError = "Couldn't play the demo clip: \(error.localizedDescription)"
        }
    }
    #endif
}
