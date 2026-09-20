import XCTest
import AVFoundation
@testable import Brownmellon

/// `MockGlassesSession` is what every feature's Simulator tests drive, so its
/// test hooks have to behave like the hardware they stand in for: the audio
/// tap gets real PCM buffers in the file's format, `stubbedPhoto` replaces
/// the picker, and `speak` never leaves a caller hanging.
@MainActor
final class MockGlassesSessionTests: XCTestCase {
    private var mock: MockGlassesSession!

    override func setUp() async throws {
        try await super.setUp()
        mock = MockGlassesSession()
    }

    // MARK: - simulateAudio

    private static let sampleRate: Double = 16_000

    /// One second of a 440 Hz sine at 16 kHz mono, as a WAV in a temp file.
    private func writeSineWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sine-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1))
        let frames = AVAudioFrameCount(Self.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) {
            samples[i] = Float(sin(2 * .pi * 440 * Double(i) / Self.sampleRate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSimulateAudioDeliversWholeFileToTapInChunks() async throws {
        let url = try writeSineWAV()
        let collector = BufferCollector()
        mock.startAudioTap { buffer, when in collector.record(buffer, when) }

        try await mock.simulateAudio(fileURL: url)

        let delivered = collector.snapshot()
        XCTAssertEqual(delivered.count, 4, "16000 frames in 4096-frame buffers")
        XCTAssertEqual(delivered.map(\.frames), [4096, 4096, 4096, 3712])
        XCTAssertEqual(delivered.reduce(0) { $0 + $1.frames }, Int(Self.sampleRate))
        XCTAssertEqual(delivered.map(\.sampleTime), [0, 4096, 8192, 12288], "timestamps advance with the audio")
        XCTAssertTrue(delivered.allSatisfy { $0.sampleRate == Self.sampleRate })
        XCTAssertTrue(delivered.allSatisfy { $0.channels == 1 })
        XCTAssertGreaterThan(delivered[0].peak, 0.9, "the buffers carry the signal, not silence")
        XCTAssertGreaterThan(delivered[3].peak, 0.9)
    }

    func testSimulateAudioDeliversOffTheMainThread() async throws {
        let url = try writeSineWAV()
        let collector = BufferCollector()
        mock.startAudioTap { buffer, when in collector.record(buffer, when) }

        try await mock.simulateAudio(fileURL: url)

        XCTAssertFalse(collector.snapshot().isEmpty)
        XCTAssertFalse(collector.sawMainThread, "hardware delivers on the audio thread; the mock must not hide main-actor assumptions")
    }

    func testSimulateAudioRealtimeTakesAboutTheClipDuration() async throws {
        let url = try writeSineWAV()
        let collector = BufferCollector()
        mock.startAudioTap { buffer, when in collector.record(buffer, when) }

        let started = Date()
        try await mock.simulateAudio(fileURL: url, realtime: true)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(collector.snapshot().count, 4)
        XCTAssertGreaterThanOrEqual(elapsed, 0.9, "a 1 s clip should take about 1 s in realtime mode")
        XCTAssertLessThan(elapsed, 3.0)
    }

    func testSimulateAudioWithoutTapIsANoOp() async throws {
        let url = try writeSineWAV()
        try await mock.simulateAudio(fileURL: url)   // must not throw
    }

    func testStopAudioTapStopsDelivery() async throws {
        let url = try writeSineWAV()
        let collector = BufferCollector()
        mock.startAudioTap { buffer, when in collector.record(buffer, when) }
        mock.stopAudioTap()

        try await mock.simulateAudio(fileURL: url)

        XCTAssertTrue(collector.snapshot().isEmpty)
    }

    // MARK: - stubbedPhoto

    func testStubbedPhotoShortCircuitsCapture() async throws {
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        mock.stubbedPhoto = photo

        let captured = try await mock.capturePhoto()

        XCTAssertTrue(captured === photo, "the exact stubbed image comes back, no picker involved")
    }

    // MARK: - speak

    func testSpeakingEmptyTextReturnsImmediately() async {
        var spoken: [String] = []
        mock.onSpeak = { spoken.append($0) }

        await mock.speak("")
        await mock.speak("   \n")

        XCTAssertEqual(spoken, ["", "   \n"], "onSpeak still reports it; only TTS is skipped")
        XCTAssertFalse(mock.isSpeaking)
    }

    /// Under XCTest the mock defaults to instant speech, so tests that await
    /// whole commands never wait on TTS (or on the no-audio fallback deadline).
    func testSpeechIsInstantUnderTests() async {
        XCTAssertEqual(mock.speechTiming, .instant)
        var spoken: [String] = []
        mock.onSpeak = { spoken.append($0) }

        let started = Date()
        await mock.speak("This is a long reply with quite a few words in it, which would take a while to say out loud.")

        XCTAssertEqual(spoken.count, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertFalse(mock.isSpeaking)
    }

    /// Simulator audio comes and goes (headless CI, no output device). Whether
    /// the synthesizer finishes normally or never reports back, `speak` must
    /// return in bounded time and `isSpeaking` must clear — otherwise the
    /// coordinator and every handler awaiting speech would hang, and features
    /// that mute the mic while speaking would stay deaf.
    func testSpeakReturnsInBoundedTimeAndClearsIsSpeaking() async throws {
        mock.speechTiming = .realtime   // the path the Simulator demo uses
        let done = expectation(description: "speak returned")
        Task {
            await mock.speak("Testing.")
            done.fulfill()
        }
        // One word: the mock's deadline is 2.5 s + 0.75 s, well under this.
        await fulfillment(of: [done], timeout: 10)
        XCTAssertFalse(mock.isSpeaking)
    }

    /// Two overlapping utterances (a sound alert landing mid-reminder) must
    /// each resume their own caller — a single continuation slot would leak
    /// one of them and hang that caller for good.
    func testOverlappingSpeakCallsBothReturn() async throws {
        mock.speechTiming = .realtime
        let first = expectation(description: "first speak returned")
        let second = expectation(description: "second speak returned")
        Task {
            await mock.speak("First thing.")
            first.fulfill()
        }
        Task {
            await mock.speak("Second thing.")
            second.fulfill()
        }
        await fulfillment(of: [first, second], timeout: 15)
        XCTAssertFalse(mock.isSpeaking)
    }
}

/// Thread-safe sink for tap callbacks, which arrive off the main actor.
private final class BufferCollector: @unchecked Sendable {
    struct Entry {
        let frames: Int
        let sampleTime: Int64
        let sampleRate: Double
        let channels: Int
        let peak: Float
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var _sawMainThread = false

    func record(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<frames { peak = max(peak, abs(channel[i])) }
        }
        let entry = Entry(
            frames: frames,
            sampleTime: when.sampleTime,
            sampleRate: buffer.format.sampleRate,
            channels: Int(buffer.format.channelCount),
            peak: peak
        )
        let onMain = Thread.isMainThread
        lock.lock()
        entries.append(entry)
        if onMain { _sawMainThread = true }
        lock.unlock()
    }

    func snapshot() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    var sawMainThread: Bool {
        lock.lock(); defer { lock.unlock() }
        return _sawMainThread
    }
}
