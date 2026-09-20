import Foundation
import UIKit
import CoreLocation
import XCTest
@testable import Brownmellon

// Shared stand-ins for the memory handler's collaborators. None of them
// touches the network, Core Location or Maps, so the handler's whole
// behavior — including the voice path — runs on a bare test runner.

/// Fixed-answer OCR. `result` is what `readSignText` returns or throws.
@MainActor
final class StubSignReader: ParkingSignReader {
    var result: Result<String, Error> = .success("")
    private(set) var imagesRead: [UIImage] = []

    func readSignText(from image: UIImage) async throws -> String {
        imagesRead.append(image)
        return try result.get()
    }
}

/// Records every recall request and answers with `result`.
@MainActor
final class StubRecallClient: RecallAnswering {
    struct Request: Equatable {
        let question: String
        let notes: [MemoryNote]
    }

    var result: Result<RecallAnswer, Error> = .success(RecallAnswer(answer: "", matchedNoteIds: []))
    private(set) var requests: [Request] = []
    var hitCount: Int { requests.count }

    func answer(question: String, notes: [MemoryNote], now: Date, timeZone: TimeZone) async throws -> RecallAnswer {
        requests.append(Request(question: question, notes: notes))
        return try result.get()
    }
}

/// Returns a scripted outcome; counts how often the handler asked.
@MainActor
final class StubLocationFixProvider: LocationFixProvider {
    var outcome: LocationFixOutcome = .unavailable
    private(set) var requestCount = 0

    func requestFix() async -> LocationFixOutcome {
        requestCount += 1
        return outcome
    }
}

@MainActor
final class SpyDirectionsOpener: DirectionsOpener {
    private(set) var opened: [CLLocationCoordinate2D] = []

    func openWalkingDirections(to coordinate: CLLocationCoordinate2D) {
        opened.append(coordinate)
    }
}

/// Injected `now` for the handler and the notes it creates.
@MainActor
final class TestClock {
    var now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.now = now }
    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

struct StubFailure: Error {}

enum TestImages {
    static func blank(_ size: CGFloat = 8) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in }
    }
}

extension XCTestCase {
    /// Runs `action` without waiting for TTS to finish (the mock's `speak`
    /// awaits real playback, or a deadline when Simulator audio is absent)
    /// and returns the first line the glasses were asked to say.
    @MainActor
    func firstSpokenLine(
        from mock: MockGlassesSession,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        during action: @escaping @MainActor () async -> Void
    ) async -> String? {
        let recorder = SpeechRecorder()
        let spoken = expectation(description: "glasses spoke")
        mock.onSpeak = { text in
            if recorder.record(text) { spoken.fulfill() }
        }
        Task { await action() }
        await fulfillment(of: [spoken], timeout: timeout)
        if recorder.first == nil {
            XCTFail("nothing was spoken", file: file, line: line)
        }
        return recorder.first
    }
}

/// Keeps only the first utterance and reports whether a call was the first,
/// so an expectation is never fulfilled twice.
@MainActor
final class SpeechRecorder {
    private(set) var first: String?

    /// True exactly once.
    func record(_ text: String) -> Bool {
        guard first == nil else { return false }
        first = text
        return true
    }
}
