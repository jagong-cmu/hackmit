import XCTest
@testable import Brownmellon

/// The pipeline around the pure pieces: capture → extract → cache → speak,
/// with an injectable clock for the 5-minute / 60-second rules and a stub
/// backend for the legibility retry. Uses `FakeGlassesSession` so `speak`
/// returns at once; the real Simulator session is exercised by
/// `FoodLabelVoicePathTests`.
@MainActor
final class FoodLabelViewModelTests: XCTestCase {
    private var glasses: FakeGlassesSession!
    private var store: MockSecureLocalStore!
    private var backend: StubFoodLabelBackend!
    private var now: Date!

    override func setUp() async throws {
        try await super.setUp()
        glasses = FakeGlassesSession()
        store = MockSecureLocalStore()
        try store.save(DietaryProfile.lowSodiumPeanutAllergy, forKey: DietaryProfile.storageKey)
        backend = StubFoodLabelBackend(try FoodLabelFixtures.soup())
        now = Date()
    }

    private func makeViewModel() -> FoodLabelViewModel {
        FoodLabelViewModel(glasses: glasses, store: store, backend: backend, now: { [unowned self] in self.now })
    }

    private func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }

    // MARK: - Modes

    func testCheckSpeaksTheVerdict() async {
        let vm = makeViewModel()
        await vm.checkFood()
        XCTAssertEqual(glasses.spoken.count, 1)
        XCTAssertTrue(glasses.spoken[0].contains("doesn't fit your low-sodium diet"))
        XCTAssertEqual(vm.state, .done)
        XCTAssertEqual(vm.lastSpoken, glasses.spoken[0])
        XCTAssertEqual(vm.lastAssessment?.verdict, .doesNotFit)
        XCTAssertEqual(vm.lastLabel?.productName, "Campbell's Chicken Noodle Soup")
    }

    func testReadSpeaksTheHeadline() async {
        let vm = makeViewModel()
        await vm.readLabel()
        XCTAssertTrue(glasses.spoken[0].hasPrefix("This is Campbell's Chicken Noodle Soup. One serving is 1 cup"))
        XCTAssertTrue(glasses.spoken[0].hasSuffix(FoodLabelSpeech.offer))
    }

    func testNoProfileReadsTheLabelInstead() async {
        store = MockSecureLocalStore()   // nothing saved
        let vm = makeViewModel()
        await vm.checkFood()
        XCTAssertTrue(glasses.spoken[0].hasPrefix(FoodLabelSpeech.noProfileLeadIn))
        XCTAssertTrue(glasses.spoken[0].contains("890 milligrams of sodium"))
        XCTAssertEqual(vm.lastAssessment?.verdict, .noProfile)
    }

    func testProfileChangesApplyToTheNextCommand() async throws {
        let vm = makeViewModel()
        await vm.checkFood()
        XCTAssertEqual(vm.lastAssessment?.verdict, .doesNotFit)

        try store.save(DietaryProfile.allergy(.peanuts), forKey: DietaryProfile.storageKey)
        advance(30)
        await vm.checkFood()
        XCTAssertEqual(vm.lastAssessment?.verdict, .fits, "the caregiver's edit applies without restarting")
    }

    // MARK: - Cache

    func testFollowUpWithinFiveMinutesSkipsThePhoto() async {
        let vm = makeViewModel()
        await vm.checkFood()
        advance(4 * 60)
        await vm.run(.read(.ingredients))
        advance(30)
        await vm.run(.question(.sodium))

        XCTAssertEqual(glasses.captureCount, 1, "one photo for three commands")
        XCTAssertEqual(backend.callCount, 1)
        XCTAssertTrue(glasses.spoken[1].hasPrefix(FoodLabelSpeech.cachePrefix))
        XCTAssertTrue(glasses.spoken[1].contains("The ingredients are Chicken stock"))
        XCTAssertEqual(glasses.spoken[2], FoodLabelSpeech.cachePrefix + "890 milligrams of sodium per serving — that's more than half of your daily limit.")
    }

    func testFollowUpAfterFiveMinutesTakesANewPhoto() async {
        let vm = makeViewModel()
        await vm.checkFood()
        advance(5 * 60 + 1)
        await vm.run(.question(.sodium))

        XCTAssertEqual(glasses.captureCount, 2)
        XCTAssertFalse(glasses.spoken[1].hasPrefix(FoodLabelSpeech.cachePrefix))
    }

    func testCheckWithinSixtySecondsOfTheLastCommandReusesTheLabel() async {
        let vm = makeViewModel()
        await vm.readLabel()
        advance(45)
        await vm.checkFood()

        XCTAssertEqual(glasses.captureCount, 1)
        XCTAssertTrue(glasses.spoken[1].hasPrefix(FoodLabelSpeech.cachePrefix + "This is Campbell's"))
    }

    func testCheckAfterSixtySecondsRephotographs() async {
        let vm = makeViewModel()
        await vm.checkFood()
        advance(61)
        await vm.checkFood()

        XCTAssertEqual(glasses.captureCount, 2, "check mode re-photographs — the wearer may be holding a new package")
        XCTAssertFalse(glasses.spoken[1].hasPrefix(FoodLabelSpeech.cachePrefix))
    }

    func testFreshReadThisLabelAfterSixtySecondsRephotographs() async {
        let vm = makeViewModel()
        await vm.checkFood()
        advance(90)
        await vm.readLabel()
        XCTAssertEqual(glasses.captureCount, 2)
    }

    func testNotALabelIsNotCached() async throws {
        backend.results = [try FoodLabelFixtures.notALabel(), try FoodLabelFixtures.soup()]
        let vm = makeViewModel()
        await vm.checkFood()
        XCTAssertEqual(glasses.spoken[0], FoodLabelSpeech.notALabelScript)
        XCTAssertNil(vm.lastLabel)

        advance(5)
        await vm.run(.question(.sodium))
        XCTAssertEqual(glasses.captureCount, 2, "nothing to answer from — take a new photo")
        XCTAssertEqual(glasses.spoken[1], "890 milligrams of sodium per serving — that's more than half of your daily limit.")
    }

    func testCheckAfterAFailedCaptureRephotographsInsteadOfReplayingTheOldLabel() async throws {
        // Soup at t=0; a wall at t=100 (not a label); a new package at t=130.
        // The wall was not "a command on this label", so the 60 s same-label
        // window must not make the third check replay the soup verdict.
        backend.results = [try FoodLabelFixtures.soup(), try FoodLabelFixtures.notALabel(), try FoodLabelFixtures.beans()]
        let vm = makeViewModel()
        await vm.checkFood()
        XCTAssertEqual(vm.lastAssessment?.verdict, .doesNotFit)

        advance(100)
        await vm.checkFood()
        XCTAssertEqual(glasses.spoken[1], FoodLabelSpeech.notALabelScript)

        advance(30)
        await vm.checkFood()
        XCTAssertEqual(glasses.captureCount, 3, "a fresh photo, not the cached soup")
        XCTAssertEqual(vm.lastAssessment?.verdict, .fits)
        XCTAssertFalse(glasses.spoken[2].hasPrefix(FoodLabelSpeech.cachePrefix), glasses.spoken[2])
        XCTAssertTrue(glasses.spoken[2].contains("Del Monte"), glasses.spoken[2])
    }

    func testWhatElseNeverTakesAPhoto() async {
        let vm = makeViewModel()
        await vm.run(.question(.whatElse))
        XCTAssertEqual(glasses.captureCount, 0)
        XCTAssertEqual(glasses.spoken[0], FoodLabelSpeech.whatElseScript(nil))

        await vm.checkFood()
        await vm.run(.question(.whatElse))
        XCTAssertEqual(glasses.captureCount, 1)
        XCTAssertEqual(glasses.spoken[2], "Nothing else to watch on this label.")
    }

    // MARK: - Legibility retry

    func testRetriesOnceAtLargerSizeWhenNeededNutrientsAreUnreadable() async throws {
        var profile = DietaryProfile.lowSodiumOnly
        profile.carbAware = true
        profile.lowSaturatedFat = true
        try store.save(profile, forKey: DietaryProfile.storageKey)
        backend.results = [try FoodLabelFixtures.unreadable(), try FoodLabelFixtures.soup()]

        let vm = makeViewModel()
        await vm.checkFood()

        XCTAssertEqual(backend.maxDimensions, [2048, 3000])
        XCTAssertEqual(glasses.captureCount, 1, "same photo, re-encoded larger")
        XCTAssertTrue(glasses.spoken[0].contains("890 milligrams of sodium"), "the legible retry is what gets spoken")
    }

    func testNoRetryWhenTheLabelWasReadable() async {
        let vm = makeViewModel()
        await vm.checkFood()
        XCTAssertEqual(backend.maxDimensions, [2048])
    }

    func testRetryKeepsTheOriginalWhenTheRetryIsNoBetter() async throws {
        var profile = DietaryProfile.lowSodiumOnly
        profile.carbAware = true
        profile.lowSaturatedFat = true
        try store.save(profile, forKey: DietaryProfile.storageKey)
        backend.results = [try FoodLabelFixtures.unreadable()]   // the retry returns the same

        let vm = makeViewModel()
        await vm.checkFood()

        XCTAssertEqual(backend.maxDimensions, [2048, 3000])
        XCTAssertEqual(vm.lastAssessment?.verdict, .unknown)
        XCTAssertEqual(
            glasses.spoken[0],
            "I could read most of this label, but the sodium, the carbohydrates, and the saturated fat weren't legible. Try a closer photo of the Nutrition Facts panel. Hold it about a foot from your face."
        )
    }

    func testNoRetryWhenOnlyOneNeededNutrientIsMissing() async throws {
        backend.results = [try FoodLabelFixtures.unreadable()]   // low-sodium profile needs only sodium
        let vm = makeViewModel()
        await vm.checkFood()
        XCTAssertEqual(backend.maxDimensions, [2048], "one missing number is below the retry threshold")
        XCTAssertEqual(vm.lastAssessment?.verdict, .unknown)
    }

    func testUnreadableCountFollowsTheProfile() throws {
        let unreadable = try FoodLabelFixtures.unreadable()   // calories, fat, protein read; the rest nil
        XCTAssertEqual(FoodLabelViewModel.unreadableNeededCount(unreadable, .lowSodiumOnly), 1)
        var profile = DietaryProfile.lowSodiumOnly
        profile.carbAware = true
        profile.lowSaturatedFat = true
        XCTAssertEqual(FoodLabelViewModel.unreadableNeededCount(unreadable, profile), 5)
        XCTAssertEqual(FoodLabelViewModel.unreadableNeededCount(unreadable, DietaryProfile()), 2, "headline fields stand in when no nutrient rule is active")
        XCTAssertEqual(FoodLabelViewModel.unreadableNeededCount(try FoodLabelFixtures.soup(), profile), 0)
    }

    // MARK: - Errors

    func testQuotaErrorSpeaksTheSharedQuotaMessage() async {
        backend.error = FoodLabelBackendError.serverError(429)
        let vm = makeViewModel()
        await vm.checkFood()
        XCTAssertEqual(glasses.spoken, [BackendErrors.quotaMessage])
        guard case .failed = vm.state else { return XCTFail("expected failed state, got \(vm.state)") }
    }

    func testBackendFailureSpeaksAGenericMessage() async {
        backend.error = FoodLabelBackendError.serverError(502)
        let vm = makeViewModel()
        await vm.checkFood()
        XCTAssertEqual(glasses.spoken, ["Something went wrong reading that label. Let's try again."])
    }

    func testCaptureFailureSpeaksAPhotoMessage() async {
        glasses.captureError = MockGlassesSessionError.noImageSelected
        let vm = makeViewModel()
        await vm.checkFood()
        XCTAssertEqual(glasses.spoken, ["I couldn't take a photo. Let's try again."])
        XCTAssertEqual(backend.callCount, 0)
    }

    // MARK: - Handler contract

    func testHandleClaimsOnlyItsOwnPhrases() async {
        let vm = makeViewModel()
        for phrase in ["read this to me", "check this ad", "scan this", "remind me to call mom at 5", "what do i have today"] {
            let claimed = await vm.handle(phrase)
            XCTAssertFalse(claimed, phrase)
        }
        XCTAssertEqual(glasses.captureCount, 0)
        XCTAssertEqual(backend.callCount, 0)
        XCTAssertTrue(glasses.spoken.isEmpty)

        let claimed = await vm.handle("can i eat this")
        XCTAssertTrue(claimed)
        XCTAssertEqual(glasses.captureCount, 1)
    }
}
