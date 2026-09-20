import Foundation
import AVFoundation
import SoundAnalysis

/// One finished classifier window: every label with its confidence, sorted
/// most-confident first, exactly as SoundAnalysis produced it.
struct SoundWindow: Sendable {
    let classifications: [SoundClassification]
    /// Where the window sits in the analyzed stream, in seconds.
    let streamTime: TimeInterval
}

/// Runs Apple's built-in sound classifier (`SNClassifySoundRequest`,
/// `.version1`) over the mic buffers the glasses session hands us.
///
/// The tap callback arrives on the audio thread. Everything here hops to a
/// private serial queue first — the analyzer is touched on that queue only —
/// and the finished windows go out through `onWindow`, still off the main
/// actor. The analyzer is recreated whenever the incoming buffer format
/// differs from the one it was built with (the real session restarts
/// recognition every minute; be robust to a format change or a gap).
final class SoundStreamClassifier: NSObject, @unchecked Sendable {
    typealias WindowHandler = @Sendable (SoundWindow) -> Void

    private let queue = DispatchQueue(label: "com.brownmellon.hearing.analysis", qos: .userInitiated)
    private let onWindow: WindowHandler
    private let onError: (@Sendable (Error) -> Void)?
    private let windowDuration: TimeInterval
    private let overlapFactor: Double

    // Accessed on `queue` only.
    private var analyzer: SNAudioStreamAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    /// Our own running frame position: the analyzer needs monotonic positions,
    /// and the mock replays clips from frame 0 each time.
    private var framePosition: AVAudioFramePosition = 0
    private var finished = false

    init(
        windowDuration: TimeInterval = 1.5,
        overlapFactor: Double = 0.5,
        onError: (@Sendable (Error) -> Void)? = nil,
        onWindow: @escaping WindowHandler
    ) {
        self.windowDuration = windowDuration
        self.overlapFactor = overlapFactor
        self.onError = onError
        self.onWindow = onWindow
        super.init()
    }

    /// Safe to call from the audio thread; returns immediately.
    func analyze(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        queue.async { [self] in
            guard !finished, let analyzer = reusableAnalyzer(for: buffer.format) else { return }
            analyzer.analyze(buffer, atAudioFramePosition: framePosition)
            framePosition += AVAudioFramePosition(buffer.frameLength)
        }
    }

    /// Stops delivering windows and releases the analyzer.
    func finish() {
        queue.async { [self] in
            finished = true
            analyzer?.completeAnalysis()
            analyzer = nil
            analyzerFormat = nil
        }
    }

    /// The current analyzer if `format` matches the one it was built with,
    /// otherwise a fresh one for this format.
    private func reusableAnalyzer(for format: AVAudioFormat) -> SNAudioStreamAnalyzer? {
        if let analyzer, let analyzerFormat, analyzerFormat == format {
            return analyzer
        }
        analyzer?.completeAnalysis()
        analyzer = nil
        analyzerFormat = nil
        framePosition = 0

        let fresh = SNAudioStreamAnalyzer(format: format)
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTimeMakeWithSeconds(windowDuration, preferredTimescale: 48_000)
            request.overlapFactor = overlapFactor
            try fresh.add(request, withObserver: self)
        } catch {
            onError?(error)
            return nil
        }
        analyzer = fresh
        analyzerFormat = format
        return fresh
    }
}

// MARK: - SNResultsObserving

extension SoundStreamClassifier: SNResultsObserving {
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let window = SoundWindow(
            classifications: result.classifications.map {
                SoundClassification(identifier: $0.identifier, confidence: $0.confidence)
            },
            streamTime: CMTimeGetSeconds(result.timeRange.start)
        )
        onWindow(window)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        onError?(error)
    }

    func requestDidComplete(_ request: SNRequest) {}
}
