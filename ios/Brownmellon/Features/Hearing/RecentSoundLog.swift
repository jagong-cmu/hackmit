import Foundation

/// One classifier hit worth remembering: a label, how sure the classifier
/// was, and when. Never audio.
struct RecentSoundObservation: Equatable, Sendable {
    let identifier: String
    let confidence: Double
    let timestamp: Date
}

/// The last 60 seconds of *labels* — what "Hey Dojo, what was that?" answers
/// from (PRD-sound-alerts § 8b). Holds catalog labels at ≥ 0.4 confidence
/// whether or not the caregiver enabled them; nothing is ever recorded or
/// uploaded, only these small tuples, and they age out after a minute.
///
/// Thread-safe so the analysis side can append while the voice handler reads.
final class RecentSoundLog: @unchecked Sendable {
    let window: TimeInterval
    let minimumConfidence: Double
    private let capacity: Int
    private let lock = NSLock()
    private var observations: [RecentSoundObservation] = []

    init(window: TimeInterval = 60, minimumConfidence: Double = 0.4, capacity: Int = 512) {
        self.window = window
        self.minimumConfidence = minimumConfidence
        self.capacity = capacity
    }

    /// Appends when `confidence` clears `minimumConfidence`; otherwise a no-op.
    func record(_ identifier: String, confidence: Double, at timestamp: Date) {
        guard confidence >= minimumConfidence else { return }
        lock.lock()
        defer { lock.unlock() }
        observations.append(RecentSoundObservation(identifier: identifier, confidence: confidence, timestamp: timestamp))
        if observations.count > capacity {
            observations.removeFirst(observations.count - capacity)
        }
    }

    /// Everything still inside the window, oldest first.
    func observations(now: Date) -> [RecentSoundObservation] {
        lock.lock()
        defer { lock.unlock() }
        prune(now: now)
        return observations
    }

    /// "Most recent, most confident": the single observation to report. Looks
    /// at the newest hit and anything within `ongoingGap` before it (one
    /// sound produces several overlapping windows), and picks the most
    /// confident of those.
    func mostNotable(now: Date, ongoingGap: TimeInterval = 3.0) -> RecentSoundObservation? {
        let recent = observations(now: now)
        guard let newest = recent.last else { return nil }
        let cutoff = newest.timestamp.addingTimeInterval(-ongoingGap)
        return recent
            .filter { $0.timestamp >= cutoff }
            .max { lhs, rhs in
                if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }
                return lhs.timestamp < rhs.timestamp
            }
    }

    func clear() {
        lock.lock()
        observations.removeAll()
        lock.unlock()
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-window)
        observations.removeAll { $0.timestamp < cutoff }
    }
}
