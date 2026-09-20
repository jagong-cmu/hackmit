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
    private var lastDelivered: String?

    init(settleInterval: TimeInterval = TranscriptSettler.defaultSettleInterval, deliver: @escaping (String) -> Void) {
        self.settleInterval = settleInterval
        self.deliver = deliver
    }

    /// Feed every recognizer result here, partial or final.
    func ingest(_ text: String, isFinal: Bool) {
        pending?.cancel()
        pending = nil

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastDelivered else { return }

        if isFinal || settleInterval <= 0 {
            fire(trimmed)
            return
        }

        let nanoseconds = UInt64(settleInterval * 1_000_000_000)
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.fire(trimmed)
        }
    }

    /// Forget the current utterance — call when a fresh recognition task starts
    /// so the next sentence is judged on its own.
    func reset() {
        pending?.cancel()
        pending = nil
        lastDelivered = nil
    }

    private func fire(_ text: String) {
        lastDelivered = text
        deliver(text)
    }
}
