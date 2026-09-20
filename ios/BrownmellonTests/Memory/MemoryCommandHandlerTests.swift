import XCTest
import CoreLocation
@testable import Brownmellon

/// The handler drives the store, GPS, the sign photo, the recall backend and
/// speech. Every collaborator is stubbed, so these assert the exact spoken
/// copy from the PRD for each branch — and that the parking recall path
/// never reaches the backend.
@MainActor
final class MemoryCommandHandlerTests: XCTestCase {
    private var mock: MockGlassesSession!
    private var store: MemoryStore!
    private var signReader: StubSignReader!
    private var recall: StubRecallClient!
    private var location: StubLocationFixProvider!
    private var directions: SpyDirectionsOpener!
    private var clock: TestClock!
    private var handler: MemoryCommandHandler!

    private let car = LocationFix(latitude: 42.3556, longitude: -71.0648, horizontalAccuracy: 10)
    private let here = LocationFix(latitude: 42.3550, longitude: -71.0656, horizontalAccuracy: 10)

    override func setUp() async throws {
        try await super.setUp()
        mock = MockGlassesSession()
        store = MemoryStore(store: MockSecureLocalStore())
        signReader = StubSignReader()
        recall = StubRecallClient()
        location = StubLocationFixProvider()
        directions = SpyDirectionsOpener()
        clock = TestClock()
        handler = MemoryCommandHandler(
            glasses: mock,
            store: store,
            vision: signReader,
            recall: recall,
            location: location,
            directions: directions,
            now: { [clock] in clock!.now }
        )
    }

    private func say(_ command: String) async -> String? {
        await firstSpokenLine(from: mock) { [handler] in
            let handled = await handler!.handle(command)
            XCTAssertTrue(handled, "\(command) should be claimed")
        }
    }

    // MARK: - Not ours

    func testRemindIsNotClaimedAndNothingIsSpoken() async {
        var spoken: [String] = []
        mock.onSpeak = { spoken.append($0) }

        let handled = await handler.handle("remind me to take my pills at 8")

        XCTAssertFalse(handled)
        XCTAssertTrue(spoken.isEmpty)
        XCTAssertTrue(store.notes.isEmpty)
    }

    // MARK: - 9a Save

    func testPlainNoteIsSavedWithLocationAndReadBack() async {
        location.outcome = .fix(car)

        let line = await say("remember i put my glasses case in the kitchen drawer")

        XCTAssertEqual(line, "Got it. I'll remember: I put my glasses case in the kitchen drawer.")
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.kind, .general)
        XCTAssertEqual(store.notes.first?.text, "i put my glasses case in the kitchen drawer")
        XCTAssertEqual(store.notes.first?.latitude, car.latitude)
        XCTAssertEqual(store.notes.first?.longitude, car.longitude)
        XCTAssertEqual(store.notes.first?.horizontalAccuracy, car.horizontalAccuracy)
        XCTAssertEqual(store.notes.first?.createdAt, clock.now)
        XCTAssertTrue(signReader.imagesRead.isEmpty, "no photo for a text note")
    }

    func testTextParkingNoteWithoutPermissionStillSavesTheWords() async {
        location.outcome = .denied

        let line = await say("remember i parked in section b")

        XCTAssertEqual(line, "Got it. I'll remember: I parked in section B.")
        XCTAssertEqual(store.notes.first?.kind, .parking)
        XCTAssertFalse(store.notes.first?.hasLocation ?? true, "a denied fix never blocks the save")
    }

    func testEmptyRememberIsRejected() async {
        let line = await say("remember")

        XCTAssertEqual(line, "Remember what? Try: Hey Dojo, remember I parked in section B.")
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertEqual(location.requestCount, 0, "no GPS prompt for a rejected save")
    }

    func testParkingPhotoWithReadableSign() async {
        let photo = TestImages.blank()
        mock.stubbedPhoto = photo
        signReader.result = .success("LEVEL 3\nROW F")
        location.outcome = .fix(car)

        let line = await say("remember where i parked")

        XCTAssertEqual(line, "Got it. I saved your parking spot — the sign says Level 3, Row F.")
        XCTAssertEqual(signReader.imagesRead.count, 1)
        XCTAssertTrue(signReader.imagesRead.first === photo, "the captured frame goes to OCR")
        let note = store.newestParking
        XCTAssertEqual(note?.kind, .parking)
        XCTAssertEqual(note?.text, "")
        XCTAssertEqual(note?.signText, "Level 3, Row F")
        XCTAssertEqual(note?.latitude, car.latitude)
    }

    func testParkingPhotoFailureIsSilentWhenLocationSaved() async {
        mock.stubbedPhoto = TestImages.blank()
        signReader.result = .failure(StubFailure())
        location.outcome = .fix(car)

        let line = await say("remember my parking spot")

        XCTAssertEqual(line, "Got it. I saved where you're parked.")
        XCTAssertEqual(store.newestParking?.latitude, car.latitude)
        XCTAssertNil(store.newestParking?.signText)
    }

    func testParkingPhotoReadNothingAndLocationUnavailable() async {
        mock.stubbedPhoto = TestImages.blank()
        signReader.result = .success("   \n")
        location.outcome = .unavailable

        let line = await say("remember where i m parked")

        XCTAssertEqual(line, "Got it. I saved where you're parked.")
        XCTAssertEqual(store.notes.count, 1, "the note is kept so 'where did I park' has something to say")
    }

    func testParkingPhotoReadNothingAndLocationDenied() async {
        mock.stubbedPhoto = TestImages.blank()
        signReader.result = .success("")
        location.outcome = .denied

        let line = await say("remember where i parked")

        XCTAssertEqual(
            line,
            "Got it. I saved a note that you parked, but I can't save the location without permission. You can turn it on in Settings."
        )
        XCTAssertEqual(store.notes.count, 1)
    }

    func testSignTextIsCappedAtOneHundredTwentyCharacters() async {
        mock.stubbedPhoto = TestImages.blank()
        signReader.result = .success(Array(repeating: "row", count: 80).joined(separator: " "))
        location.outcome = .unavailable

        _ = await say("remember where i parked")

        let sign = store.newestParking?.signText ?? ""
        XCTAssertFalse(sign.isEmpty)
        XCTAssertLessThanOrEqual(sign.count, MemoryCommandHandler.signTextMaxLength)
    }

    // MARK: - 9b Parking recall (offline)

    func testParkingRecallWithNothingSaved() async {
        let line = await say("where did i park")

        XCTAssertEqual(line, "I don't have a parking spot saved. Next time, say: Hey Dojo, remember where I parked.")
        XCTAssertEqual(recall.hitCount, 0)
        XCTAssertEqual(location.requestCount, 0, "no GPS without a note to compare against")
    }

    func testParkingRecallSpeaksSignElapsedDistanceAndDirectionWithoutTheBackend() async throws {
        try store.add(MemoryNote(
            kind: .parking, text: "", signText: "Level 3, Row F",
            createdAt: clock.now.addingTimeInterval(-2 * 3600),
            latitude: car.latitude, longitude: car.longitude, horizontalAccuracy: 10
        ))
        location.outcome = .fix(here)

        let line = await say("where s my car")

        let spoken = try XCTUnwrap(line)
        XCTAssertTrue(spoken.hasPrefix("You parked about two hours ago. The sign said Level 3, Row F. Your car is about "), spoken)
        XCTAssertTrue(spoken.hasSuffix(" feet to the northeast."), spoken)
        XCTAssertEqual(recall.hitCount, 0, "parking recall is answered on-device")
        XCTAssertEqual(location.requestCount, 1)
    }

    /// "Remember the car is in lot B" is a general note, but it is the honest
    /// answer to "where's my car" when nothing was saved as parking.
    func testParkingRecallFallsBackToAGeneralNoteAboutTheCar() async throws {
        try store.add(MemoryNote(kind: .general, text: "keys are on the hook", createdAt: clock.now.addingTimeInterval(-5)))
        try store.add(MemoryNote(kind: .general, text: "the car is in lot b", createdAt: clock.now.addingTimeInterval(-20)))

        let line = await say("where s my car")

        XCTAssertEqual(line, "You told me just now: The car is in lot B.")
        XCTAssertEqual(recall.hitCount, 0)
    }

    /// "Forget it" is a cancel, never a delete.
    func testForgetItDeletesNothing() async throws {
        try store.add(MemoryNote(kind: .parking, text: "i parked in section b", createdAt: clock.now))

        let line = await say("forget it")

        XCTAssertEqual(line, "Okay.")
        XCTAssertEqual(store.notes.count, 1, "the parking note must survive a 'forget it'")
    }

    func testParkingRecallOfATextNoteSaysJustNow() async throws {
        try store.add(MemoryNote(kind: .parking, text: "i parked in section b", createdAt: clock.now.addingTimeInterval(-10)))

        let line = await say("where did i park")

        XCTAssertEqual(line, "You told me just now: I parked in section B.")
        XCTAssertEqual(recall.hitCount, 0)
    }

    func testParkingRecallUsesTheNewestParkingNoteAndFlagsOldOnes() async throws {
        try store.add(MemoryNote(kind: .parking, text: "i parked in lot a", createdAt: clock.now.addingTimeInterval(-3 * 86_400)))
        try store.add(MemoryNote(kind: .parking, text: "i parked in section b", createdAt: clock.now.addingTimeInterval(-30 * 3600)))
        try store.add(MemoryNote(kind: .general, text: "keys are on the hook", createdAt: clock.now.addingTimeInterval(-60)))

        let line = await say("where did i park")

        XCTAssertEqual(line, "This might be old — you told me about one day ago: I parked in section B.")
    }

    // MARK: - 9b Directions

    func testDirectionsOpenMapsAtTheSavedCoordinate() async throws {
        try store.add(MemoryNote(kind: .parking, text: "", createdAt: clock.now, latitude: car.latitude, longitude: car.longitude, horizontalAccuracy: 10))

        let line = await say("take me to my car")

        XCTAssertEqual(line, "Opening walking directions on your phone.")
        XCTAssertEqual(directions.opened.count, 1)
        XCTAssertEqual(directions.opened.first?.latitude, car.latitude)
        XCTAssertEqual(directions.opened.first?.longitude, car.longitude)
    }

    func testDirectionsWithoutACoordinate() async throws {
        try store.add(MemoryNote(kind: .parking, text: "i parked in section b", createdAt: clock.now))

        let line = await say("directions to my car")

        XCTAssertEqual(line, "I don't have your car's location saved.")
        XCTAssertTrue(directions.opened.isEmpty)
    }

    // MARK: - 9b General recall

    func testGeneralRecallWithNoNotesSkipsTheBackend() async {
        let line = await say("where did i put my keys")

        XCTAssertEqual(line, "You haven't asked me to remember anything yet.")
        XCTAssertEqual(recall.hitCount, 0)
    }

    func testGeneralRecallSpeaksTheBackendAnswerVerbatim() async throws {
        try store.add(MemoryNote(kind: .general, text: "i put my keys on the hook by the door", createdAt: clock.now.addingTimeInterval(-3600)))
        recall.result = .success(RecallAnswer(answer: "An hour ago you told me your keys are on the hook by the door.", matchedNoteIds: []))

        let line = await say("where did i put my keys")

        XCTAssertEqual(line, "An hour ago you told me your keys are on the hook by the door.")
        XCTAssertEqual(recall.requests.count, 1)
        XCTAssertEqual(recall.requests.first?.question, "where did i put my keys")
        XCTAssertEqual(recall.requests.first?.notes, store.notes)
    }

    func testGeneralRecallSendsAtMostOneHundredNewestNotes() async throws {
        for i in 0..<150 {
            try store.add(MemoryNote(kind: .general, text: "note \(i)", createdAt: clock.now.addingTimeInterval(Double(i))))
        }
        recall.result = .success(RecallAnswer(answer: "Yesterday you said note 149.", matchedNoteIds: []))

        _ = await say("what did i tell you about notes")

        let sent = try XCTUnwrap(recall.requests.first?.notes)
        XCTAssertEqual(sent.count, RecallClient.maxNotes)
        XCTAssertEqual(sent.first?.text, "note 149", "newest first")
        XCTAssertEqual(sent.last?.text, "note 50")
    }

    func testGeneralRecallBackendFailure() async throws {
        try store.add(MemoryNote(kind: .general, text: "frank is the new neighbor", createdAt: clock.now))
        recall.result = .failure(StubFailure())

        let line = await say("what did i tell you about frank")

        XCTAssertEqual(line, "I couldn't check my notes just now. Please try again.")
    }

    func testGeneralRecallEmptyAnswerFallsBackToTheFailureLine() async throws {
        try store.add(MemoryNote(kind: .general, text: "frank is the new neighbor", createdAt: clock.now))
        recall.result = .success(RecallAnswer(answer: "  ", matchedNoteIds: []))

        let line = await say("do you remember frank")

        XCTAssertEqual(line, "I couldn't check my notes just now. Please try again.")
    }

    // MARK: - 9c Forget

    func testForgetParkingDeletesTheNewestParkingNoteOnly() async throws {
        try store.add(MemoryNote(kind: .parking, text: "i parked in lot a", createdAt: clock.now.addingTimeInterval(-7200)))
        try store.add(MemoryNote(kind: .parking, text: "i parked in section b", createdAt: clock.now.addingTimeInterval(-60)))
        try store.add(MemoryNote(kind: .general, text: "keys are on the hook", createdAt: clock.now))

        let line = await say("forget my parking spot")

        XCTAssertEqual(line, "Okay. I forgot: I parked in section B.")
        XCTAssertEqual(store.notes.map(\.text), ["keys are on the hook", "i parked in lot a"])
    }

    func testForgetPhotoOnlyParkingNoteNamesTheSign() async throws {
        try store.add(MemoryNote(kind: .parking, text: "", signText: "Level 3, Row F", createdAt: clock.now))

        let line = await say("forget where i parked")

        XCTAssertEqual(line, "Okay. I forgot your parking spot — the sign said Level 3, Row F.")
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testForgetParkingWithNothingSaved() async {
        let line = await say("forget my parking spot")
        XCTAssertEqual(line, "I don't have a parking spot saved.")
    }

    func testForgetThatDeletesTheNewestNoteOfAnyKind() async throws {
        try store.add(MemoryNote(kind: .parking, text: "i parked in section b", createdAt: clock.now.addingTimeInterval(-60)))
        try store.add(MemoryNote(kind: .general, text: "keys are on the hook", createdAt: clock.now))

        let line = await say("forget that")

        XCTAssertEqual(line, "Okay. I forgot: Keys are on the hook.")
        XCTAssertEqual(store.notes.map(\.text), ["i parked in section b"])
    }

    func testForgetLastWithNothingSaved() async {
        let line = await say("forget the last thing")
        XCTAssertEqual(line, "I don't have any notes to forget.")
    }

    func testForgetEverythingNeedsTheExactConfirmationWithinThirtySeconds() async throws {
        try store.add(MemoryNote(kind: .general, text: "a", createdAt: clock.now))
        try store.add(MemoryNote(kind: .parking, text: "b", createdAt: clock.now))

        let ask = await say("forget everything")
        XCTAssertEqual(ask, "Say 'Hey Dojo, yes, forget everything' to confirm.")
        XCTAssertEqual(store.notes.count, 2, "nothing happens until confirmed")

        clock.advance(by: 29)
        let done = await say("yes forget everything")
        XCTAssertEqual(done, "Okay. I forgot all 2 of your notes.")
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testForgetEverythingConfirmationExpires() async throws {
        try store.add(MemoryNote(kind: .general, text: "a", createdAt: clock.now))

        _ = await say("forget everything")
        clock.advance(by: 31)
        let line = await say("yes forget everything")

        XCTAssertEqual(line, "Nothing to confirm. To clear your notes, say: Hey Dojo, forget everything.")
        XCTAssertEqual(store.notes.count, 1)
    }

    func testConfirmationWithoutARequestDeletesNothing() async throws {
        try store.add(MemoryNote(kind: .general, text: "a", createdAt: clock.now))

        let line = await say("yes forget everything")

        XCTAssertEqual(line, "Nothing to confirm. To clear your notes, say: Hey Dojo, forget everything.")
        XCTAssertEqual(store.notes.count, 1)
    }

    func testForgetEverythingWithNoNotes() async {
        let line = await say("forget everything")
        XCTAssertEqual(line, "You haven't asked me to remember anything yet.")
    }

    func testUnrecognizedForgetAsksInsteadOfDeleting() async throws {
        try store.add(MemoryNote(kind: .general, text: "a", createdAt: clock.now))

        let line = await say("forget about the dentist")

        XCTAssertEqual(line, "I can forget your parking spot, the last thing you told me, or everything. Which would you like?")
        XCTAssertEqual(store.notes.count, 1)
    }
}
