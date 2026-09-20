import Foundation

/// Turns a stream of *growing* speech-recognizer partials into one delivery
/// per utterance.
///
/// `SFSpeechRecognizer` with partial results reports "hey", "hey dojo",
/// "hey dojo remember", "hey dojo remember I parked…" for a single sentence.
/// Handing each of those to the wake-word pipeline fires the first partial
/// whose command is non-empty — "remember" — before the wearer has finished
/// speaking. This holds the latest text and delivers it only once it has been
/// unchanged for `settleInterval`, or immediately when the recognizer marks
/// it final. Delivery happens on the main actor.
@MainActor
final class TranscriptSettler {
    /// Long enough to ride out a mid-sentence breath from an older speaker,
    /// short enough that the assistant still feels responsive.
    nonisolated static let defaultSettleInterval: TimeInterval = 1.0

    private let settleInterval: TimeInterval
    private let deliver: (String) -> Void
    private var pending: Task<Void, Never>?
    private var pendingText: String?
    private var lastDelivered: String?

    init(settleInterval: TimeInterval = TranscriptSettler.defaultSettleInterval, deliver: @escaping (String) -> Void) {
        self.settleInterval = settleInterval
        self.deliver = deliver
    }

    /// Feed every recognizer result here, partial or final.
    func ingest(_ text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastDelivered else {
            cancelPending()
            return
        }

        // The recognizer re-reports identical text while it firms up timings;
        // that is not a change and must not push delivery out again.
        if !isFinal, pending != nil, trimmed == pendingText { return }

        cancelPending()
        if isFinal || settleInterval <= 0 {
            fire(trimmed)
            return
        }

        pendingText = trimmed
        let nanoseconds = UInt64(settleInterval * 1_000_000_000)
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.pendingText = nil
            self.fire(trimmed)
        }
    }

    /// Deliver whatever is pending right now — for when the recognition task
    /// ends (error, time cap) before the settle interval elapsed, so a spoken
    /// command isn't silently lost.
    func flush() {
        guard let text = pendingText else { return }
        cancelPending()
        fire(text)
    }

    /// Forget the current utterance — call when listening stops so nothing
    /// from the old task can reach a new callback.
    func reset() {
        cancelPending()
        lastDelivered = nil
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
        pendingText = nil
    }

    private func fire(_ text: String) {
        lastDelivered = text
        deliver(text)
    }
}
