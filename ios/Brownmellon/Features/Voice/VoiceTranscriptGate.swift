import Foundation

/// Turns the recognizer's stream of partial transcripts into discrete events:
/// one `.command` per "Hey Dojo …" utterance, or one `.confirmation` per bare
/// "yes"/"no" while a feature is waiting on an answer.
///
/// Three properties of `GlassesSession.startListening` shape everything here:
///
///  1. **Transcripts grow.** The recognizer re-sends the whole segment as it
///     refines it, so "hey dojo remind" and "hey dojo remind me at eight" are
///     the same utterance. We hold the latest reading as a *candidate* and only
///     release it once the transcript has stopped changing for `settleDelay` —
///     otherwise the backend gets "remind" and answers "what time?".
///  2. **Segments accumulate.** Within one recognizer segment the transcript
///     keeps everything since the segment began, including commands we already
///     acted on and the assistant's own speech leaking into the mic. Everything
///     up to the last thing we acted on is *stale*; only tokens after that
///     point count. An empty transcript marks a new segment (see the
///     `GlassesSession` doc) and clears the stale prefix.
///  3. **Answers have no wake word.** After "should I add it to your calendar?"
///     the wearer just says "yes". While a confirmation is pending we read
///     bare fresh tokens through `ConfirmationDetector`, for a bounded time.
///
/// Pure with respect to time: every entry point takes `now`, and settling is
/// driven by the caller (`VoiceCommandRouter`) calling `settle` after a quiet
/// period. That keeps it unit-testable without timers.
@MainActor
final class VoiceTranscriptGate {
    enum Event: Equatable {
        case command(String)
        case confirmation(Bool)
    }

    let settleDelay: TimeInterval
    let confirmationTimeout: TimeInterval

    private let detector = WakeWordDetector()
    private let confirmations = ConfirmationDetector()

    /// Normalized tokens of the current segment, as of the last transcript.
    private var latestTokens: [String] = []
    /// Prefix of `latestTokens` already acted on or spoken over.
    private var staleCount = 0
    /// A wake-word command heard but not yet released (still settling).
    private var candidate: (command: String, lastChange: Date)?
    private var confirmationDeadline: Date?

    /// The recognizer occasionally revises earlier words in a partial, which
    /// shifts token positions by one or two. Re-reading this many stale tokens
    /// costs nothing (they never contain a fresh wake word) and stops a shifted
    /// "hey" from being cut off the front of a new command.
    private static let lookBack = 2

    // nonisolated so it can be a default argument (`VoiceCommandRouter.init`),
    // which is evaluated outside the main actor.
    nonisolated init(settleDelay: TimeInterval = 1.0, confirmationTimeout: TimeInterval = 45) {
        self.settleDelay = settleDelay
        self.confirmationTimeout = confirmationTimeout
    }

    var isAwaitingConfirmation: Bool { confirmationDeadline != nil }
    var hasPendingCommand: Bool { candidate != nil }

    /// Feed every transcript here. Returns an event to act on immediately
    /// (only confirmations are immediate — commands settle first).
    func consume(_ transcript: String, now: Date = Date()) -> Event? {
        let tokens = WakeWordDetector.tokenize(transcript)

        // Segment boundary: the recognizer started over, so nothing heard
        // before is in this transcript anymore. A candidate still settling is
        // kept — its own timer will release it.
        guard !tokens.isEmpty else {
            latestTokens = []
            staleCount = 0
            return nil
        }

        latestTokens = tokens
        let fresh = freshTokens(lookBack: Self.lookBack)

        if let deadline = confirmationDeadline {
            if now > deadline {
                confirmationDeadline = nil
            } else if detector.detectLatest(tokens: fresh) == nil,
                      // No look-back for answers: the stale tail is the end of
                      // our own question, and a question that happened to end
                      // in "…or no?" must never answer itself. A missed "yes"
                      // just gets repeated; a false one writes to the calendar.
                      let answer = confirmations.detect(in: freshTokens(lookBack: 0)) {
                confirmationDeadline = nil
                markStale()
                return .confirmation(answer)
            }
        }

        guard let match = detector.detectLatest(tokens: fresh), !match.command.isEmpty else { return nil }
        if candidate?.command != match.command {
            candidate = (match.command, now)
        }
        return nil
    }

    /// Releases the candidate command once the transcript has been quiet for
    /// `settleDelay`. The caller schedules this; see `VoiceCommandRouter`.
    func settle(now: Date = Date()) -> Event? {
        guard let candidate, now.timeIntervalSince(candidate.lastChange) >= settleDelay else { return nil }
        self.candidate = nil
        markStale()
        // A new command supersedes whatever question was open.
        confirmationDeadline = nil
        return .command(candidate.command)
    }

    /// Everything heard so far is history — call after acting on a command and
    /// after the assistant speaks, so its own words can't be mistaken for the
    /// wearer's.
    func markStale() {
        staleCount = latestTokens.count
        candidate = nil
    }

    /// Start listening for a bare yes/no. Call *after* the question has been
    /// spoken, so the question itself is already stale.
    func awaitConfirmation(now: Date = Date()) {
        markStale()
        confirmationDeadline = now.addingTimeInterval(confirmationTimeout)
    }

    func cancelConfirmation() {
        confirmationDeadline = nil
    }

    private func freshTokens(lookBack: Int) -> [String] {
        let start = max(0, min(staleCount, latestTokens.count) - lookBack)
        return Array(latestTokens[start...])
    }
}
