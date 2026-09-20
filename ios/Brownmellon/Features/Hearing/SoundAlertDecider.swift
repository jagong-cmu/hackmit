import Foundation

/// One label's score in one classifier window.
struct SoundClassification: Equatable, Sendable {
    let identifier: String
    let confidence: Double
}

/// Something the glasses should say right now.
struct SoundAlertAnnouncement: Equatable, Sendable {
    let entry: SoundCatalogEntry
    let confidence: Double
    /// Safety alerts are spoken a second time after this pause; nil otherwise.
    let repeatAfter: TimeInterval?

    var identifier: String { entry.identifier }
    var phrase: String { entry.spokenPhrase }
    var group: SoundGroup { entry.group }
    var repeatCount: Int { repeatAfter == nil ? 0 : 1 }
}

/// Pure decision logic: (classifier windows over time, settings, speaking
/// state, clock) → what to announce. No Apple frameworks beyond Foundation,
/// so every rule in PRD-sound-alerts § 8a is unit-tested with a fake clock.
///
/// Rules, in the order they are applied to each window:
///  1. While our own TTS is playing, and for `postSpeechGuard` after it stops,
///     the window is dropped — the open-ear speaker leaks into the mic.
///  2. `speech` (and anything not in the catalog) is ignored outright.
///  3. A label must clear the confidence threshold in
///     `requiredConsecutiveWindows` consecutive windows.
///  4. Per-label cooldown: 60 s after an announcement. A sound that keeps
///     going (heard again within `ongoingGap`) keeps extending it, so a smoke
///     alarm ringing for five minutes is announced once, plus its repeat, and
///     goes quiet until 60 s after it stops.
///  5. Cross-label cooldown: for `crossLabelCooldown` after an announcement,
///     same-or-lower priority labels stay quiet (one doorbell shouldn't also
///     read as "knocking"). Safety has top priority and is never suppressed by
///     another label's cooldown.
///  6. The label must be enabled — master switch and its group.
final class SoundAlertDecider {
    struct Configuration: Equatable, Sendable {
        /// After announcing a label, how long before it may be announced again.
        var labelCooldown: TimeInterval = 60
        /// After any announcement, how long same-or-lower priority labels stay quiet.
        var crossLabelCooldown: TimeInterval = 10
        /// The mic is ignored this long after our own speech ends.
        var postSpeechGuard: TimeInterval = 1.0
        /// Pause before a Safety announcement is repeated.
        var safetyRepeatDelay: TimeInterval = 2.0
        /// A label heard again within this many seconds counts as the same,
        /// still-ongoing sound (windows arrive every ~0.75 s).
        var ongoingGap: TimeInterval = 2.0
    }

    struct Outcome: Equatable {
        /// True when the whole window was dropped because we were (just) speaking.
        var suppressed: Bool
        var announcements: [SoundAlertAnnouncement]

        static let suppressedWindow = Outcome(suppressed: true, announcements: [])
    }

    var settings: SoundAlertSettings
    let configuration: Configuration
    private let catalog: [String: SoundCatalogEntry]

    /// Consecutive windows ≥ threshold, per label. Absent = 0.
    private var streaks: [String: Int] = [:]
    /// Last window in which the label cleared the threshold.
    private var lastHeardAt: [String: Date] = [:]
    /// Per label: quiet until this instant (rule 4).
    private var cooldownUntil: [String: Date] = [:]
    /// Announced labels that have been heard in every window since — the sound
    /// hasn't stopped yet, so their cooldown keeps moving (rule 4).
    private var ongoing: Set<String> = []
    /// Per announcing group: same-or-lower priority labels quiet until then (rule 5).
    private var crossCooldownUntil: [SoundGroup: Date] = [:]
    private var lastSpeakingAt: Date?
    private var wasSuppressed = false

    init(
        settings: SoundAlertSettings,
        configuration: Configuration = Configuration(),
        catalog: [SoundCatalogEntry] = SoundCatalog.entries
    ) {
        self.settings = settings
        self.configuration = configuration
        self.catalog = Dictionary(catalog.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Feed one classifier window (every label with its confidence). Labels
    /// missing from `window` are treated as below threshold.
    func evaluate(_ window: [SoundClassification], isSpeaking: Bool, now: Date) -> Outcome {
        // Rule 1 — self-suppression.
        if isSpeaking {
            lastSpeakingAt = now
            streaks.removeAll()
            wasSuppressed = true
            return .suppressedWindow
        }
        if let lastSpeakingAt, now.timeIntervalSince(lastSpeakingAt) < configuration.postSpeechGuard {
            streaks.removeAll()
            wasSuppressed = true
            return .suppressedWindow
        }
        if wasSuppressed {
            // We couldn't hear while talking; give ongoing sounds this window
            // to prove they're still going rather than counting the gap.
            for id in ongoing { lastHeardAt[id] = now }
            wasSuppressed = false
        }

        // Rules 2–3 — streaks, plus keeping ongoing sounds' cooldowns alive.
        var nextStreaks: [String: Int] = [:]
        var candidates: [(entry: SoundCatalogEntry, confidence: Double)] = []
        for classification in window {
            let id = classification.identifier
            guard !SoundCatalog.ignoredIdentifiers.contains(id),
                  let entry = catalog[id],
                  classification.confidence >= settings.confidenceThreshold else { continue }

            let streak = (streaks[id] ?? 0) + 1
            nextStreaks[id] = streak

            if ongoing.contains(id) {
                if let heard = lastHeardAt[id], now.timeIntervalSince(heard) <= configuration.ongoingGap {
                    // Still ringing: the cooldown runs from when it *stops*.
                    cooldownUntil[id] = now.addingTimeInterval(configuration.labelCooldown)
                    extendCrossCooldown(for: entry.group, now: now)
                } else {
                    // Heard again after a gap: that's a new event, not the same one.
                    ongoing.remove(id)
                }
            }
            lastHeardAt[id] = now

            if streak >= settings.requiredConsecutiveWindows {
                candidates.append((entry, classification.confidence))
            }
        }
        streaks = nextStreaks
        // A window without the label means the sound stopped.
        ongoing = ongoing.filter { nextStreaks[$0] != nil }

        // Rules 4–6 — highest priority first, then most confident.
        var announcements: [SoundAlertAnnouncement] = []
        let ordered = candidates.sorted {
            if $0.entry.group.priority != $1.entry.group.priority {
                return $0.entry.group.priority > $1.entry.group.priority
            }
            return $0.confidence > $1.confidence
        }
        for candidate in ordered {
            let entry = candidate.entry
            guard settings.isEnabled(entry.group) else { continue }
            if let until = cooldownUntil[entry.identifier], now < until { continue }
            if entry.group != .safety, isCrossSuppressed(entry.group, now: now) { continue }

            announcements.append(SoundAlertAnnouncement(
                entry: entry,
                confidence: candidate.confidence,
                repeatAfter: entry.group == .safety ? configuration.safetyRepeatDelay : nil
            ))
            cooldownUntil[entry.identifier] = now.addingTimeInterval(configuration.labelCooldown)
            ongoing.insert(entry.identifier)
            streaks[entry.identifier] = 0
            extendCrossCooldown(for: entry.group, now: now)
        }

        return Outcome(suppressed: false, announcements: announcements)
    }

    private func extendCrossCooldown(for group: SoundGroup, now: Date) {
        let until = now.addingTimeInterval(configuration.crossLabelCooldown)
        if let existing = crossCooldownUntil[group], existing > until { return }
        crossCooldownUntil[group] = until
    }

    /// Quiet if any same-or-higher priority group announced recently.
    private func isCrossSuppressed(_ group: SoundGroup, now: Date) -> Bool {
        crossCooldownUntil.contains { announcing, until in
            announcing.priority >= group.priority && now < until
        }
    }
}
