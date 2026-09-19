import Foundation
import UIKit
import XCTest
@testable import Brownmellon

@MainActor
final class ScamFeatureTests: XCTestCase {
    func testScamIntentUsesWholeWordsOnly() {
        XCTAssertTrue(ScamIntentMatcher.matches("is this a scam"))
        XCTAssertTrue(ScamIntentMatcher.matches("check this for scams"))
        XCTAssertTrue(ScamIntentMatcher.matches("SCAM?"))
        XCTAssertFalse(ScamIntentMatcher.matches("this is a scamper ad"))
        XCTAssertFalse(ScamIntentMatcher.matches("the word scamming is unrelated"))
    }

    func testSharedRouterDeduplicatesOneSpokenUtterance() async {
        let glasses = MockGlassesSession()
        let router = VoiceCommandRouter(glasses: glasses, listener: WakeWordListener(cooldown: 2))
        var scans = 0
        var schedulingCommands: [String] = []
        router.setScamHandler {
            scans += 1
        }
        router.setSchedulingHandler { command in
            schedulingCommands.append(command)
        }

        router.start()
        glasses.simulateTranscript("Hey Dojo, is this a scam?")
        await Task.yield()
        glasses.simulateTranscript("Hey Dojo, is this a scam?")
        await Task.yield()

        XCTAssertEqual(scans, 1)
        XCTAssertTrue(router.isListening)
        await router.route("remind me to call my daughter")
        XCTAssertEqual(schedulingCommands, ["remind me to call my daughter"])
        router.stop()
    }

    func testViewModelSuccessSpeaksSummaryThenActionWithoutDuplicateCapture() async throws {
        let glasses = TestGlassesSession()
        let result = ScamCheckBackendClient.Result(
            riskLevel: .high,
            spokenSummary: "This advertisement has high scam risk.",
            extractedText: "Guaranteed returns",
            observedSignals: ["Guaranteed returns"],
            verifiedFindings: [],
            aiAppearance: .unknown,
            safeAction: "Do not pay or contact the ad directly.",
            webVerificationAvailable: true
        )
        let backend = try makeBackend(result: result)
        let viewModel = AdScamCheckViewModel(glasses: glasses, backend: backend)

        async let firstCheck = viewModel.checkAd()
        async let duplicateCheck = viewModel.checkAd()
        await firstCheck
        await duplicateCheck

        guard case .completed(let completed) = viewModel.state else {
            return XCTFail("expected completed state")
        }
        XCTAssertEqual(completed, result)
        XCTAssertEqual(glasses.captureCount, 1)
        XCTAssertEqual(glasses.spoken.count, 1)
        XCTAssertTrue(glasses.spoken[0].hasPrefix(result.spokenSummary))
        XCTAssertTrue(glasses.spoken[0].hasSuffix(result.safeAction))
    }

    func testViewModelFailureStateAndRetrySpeech() async throws {
        let glasses = TestGlassesSession(shouldFailCapture: true)
        let viewModel = AdScamCheckViewModel(glasses: glasses, backend: ScamCheckBackendClient())

        await viewModel.checkAd()

        guard case .failed = viewModel.state else {
            return XCTFail("expected failed state")
        }
        XCTAssertEqual(glasses.captureCount, 1)
        XCTAssertEqual(glasses.spoken.count, 1)
        XCTAssertTrue(glasses.spoken[0].contains("try again"))
    }

    func testUnknownAndWebUnavailableResultsRemainAdvisory() async throws {
        let glasses = TestGlassesSession()
        let result = ScamCheckBackendClient.Result(
            riskLevel: .unknown,
            spokenSummary: "I couldn't read or verify enough of this advertisement.",
            extractedText: "",
            observedSignals: [],
            verifiedFindings: [],
            aiAppearance: .possible,
            safeAction: "Get a clearer image before responding.",
            webVerificationAvailable: false
        )
        let viewModel = AdScamCheckViewModel(glasses: glasses, backend: try makeBackend(result: result))
        await viewModel.checkAd()

        guard case .completed(let completed) = viewModel.state else {
            return XCTFail("expected completed state")
        }
        XCTAssertEqual(completed.riskLevel, .unknown)
        XCTAssertFalse(completed.webVerificationAvailable)
        XCTAssertEqual(completed.aiAppearance, .possible)
    }

    func testLowRiskWordingNeverSaysSafe() async throws {
        let result = ScamCheckBackendClient.Result(
            riskLevel: .low,
            spokenSummary: "I didn't find obvious scam indicators, but this does not confirm legitimacy.",
            extractedText: "Local shop",
            observedSignals: [],
            verifiedFindings: [],
            aiAppearance: .unknown,
            safeAction: "Verify the organization independently before paying.",
            webVerificationAvailable: true
        )
        let glasses = TestGlassesSession()
        let viewModel = AdScamCheckViewModel(glasses: glasses, backend: try makeBackend(result: result))
        await viewModel.checkAd()

        XCTAssertFalse(glasses.spoken.joined(separator: " ").localizedCaseInsensitiveContains("safe"))
    }

    private func makeBackend(result: ScamCheckBackendClient.Result) throws -> ScamCheckBackendClient {
        let data = try JSONEncoder().encode(result)
        let response = HTTPURLResponse(
            url: URL(string: "https://backend.example.test/api/scam-check")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return ScamCheckBackendClient(baseURL: response.url!, transport: { _ in
            (data, response)
        })
    }
}

@MainActor
private final class TestGlassesSession: GlassesSession {
    var spoken: [String] = []
    var captureCount = 0
    var shouldFailCapture: Bool

    init(shouldFailCapture: Bool = false) {
        self.shouldFailCapture = shouldFailCapture
    }

    func speak(_ text: String) async {
        spoken.append(text)
    }

    func startListening(onTranscript: @escaping (String) -> Void) {}

    func stopListening() {}

    func capturePhoto() async throws -> UIImage {
        captureCount += 1
        if shouldFailCapture { throw TestError.captureFailed }
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }
    }

    enum TestError: Error {
        case captureFailed
    }
}
