import Foundation
import CoreLocation
import UIKit

/// Feature 9 end to end: "Hey Dojo, remember …" / "where did I …" / "forget
/// …" — save, recall and forget, spoken back through the glasses.
///
/// Registered in `VoiceAssistant`'s handler chain ahead of the calendar
/// intent parser. `handle` classifies with `MemoryCommandParser` (pure string
/// checks, no network) and returns `false` fast for anything it doesn't own —
/// in particular every `remind …` command stays Feature 1's.
///
/// Privacy, visible in code: parking recall and directions never leave the
/// device (store + GPS only); the one backend call, general recall, goes
/// through `RecallClient`, whose payload has no coordinate fields.
@MainActor
final class MemoryCommandHandler: VoiceCommandHandler {
    /// "Forget everything" must be confirmed within this window.
    static let forgetAllConfirmationWindow: TimeInterval = 30
    /// How much of the spot marker's OCR we keep and read back.
    static let signTextMaxLength = 120

    let store: MemoryStore

    private let glasses: GlassesSession
    private let signReader: ParkingSignReader
    private let recall: RecallAnswering
    private let location: LocationFixProvider
    private let directions: DirectionsOpener
    private let now: () -> Date

    private var forgetAllRequestedAt: Date?

    /// `location` and `directions` default to Core Location and Apple Maps;
    /// tests inject stubs. (Built in the body because default arguments are
    /// evaluated outside the main actor.)
    init(
        glasses: GlassesSession,
        store: MemoryStore,
        vision: ParkingSignReader,
        recall: RecallAnswering,
        location: LocationFixProvider? = nil,
        directions: DirectionsOpener? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.glasses = glasses
        self.store = store
        self.signReader = vision
        self.recall = recall
        self.location = location ?? CoreLocationFixProvider()
        self.directions = directions ?? MapsDirectionsOpener()
        self.now = now
    }

    // MARK: - VoiceCommandHandler

    func handle(_ command: String) async -> Bool {
        guard let parsed = MemoryCommandParser.parse(command) else { return false }

        switch parsed {
        case let .save(text, wantsParkingPhoto, isParking):
            await save(text: text, wantsParkingPhoto: wantsParkingPhoto, isParking: isParking)
        case .recallParking:
            await recallParking()
        case .directionsToCar:
            await openDirectionsToCar()
        case let .recall(question):
            await recallGeneral(question: question)
        case .forgetLastParking:
            await forgetLastParking()
        case .forgetLast:
            await forgetLast()
        case .forgetAllRequest:
            await requestForgetAll()
        case .forgetAllConfirm:
            await confirmForgetAll()
        case .forgetUnrecognized:
            await glasses.speak(MemorySpeech.forgetHelp)
        case .dismiss:
            await glasses.speak(MemorySpeech.dismissed)
        }
        return true
    }

    // MARK: - 9a Save

    private func save(text: String, wantsParkingPhoto: Bool, isParking: Bool) async {
        guard wantsParkingPhoto || !text.isEmpty else {
            await glasses.speak(MemorySpeech.rememberWhat)
            return
        }

        // GPS and the sign photo run side by side: the fix is bounded at 5 s
        // and the OCR round-trip dominates, so the save stays inside the
        // PRD's budget. Neither can block the save — both degrade to nil.
        let fixTask = Task { @MainActor [location] in await location.requestFix() }
        let signText = wantsParkingPhoto ? await readParkingSign() : nil
        let outcome = await fixTask.value

        var note = MemoryNote(
            kind: isParking ? .parking : .general,
            text: text,
            signText: signText,
            createdAt: now()
        )
        if let fix = outcome.fix {
            note.latitude = fix.latitude
            note.longitude = fix.longitude
            note.horizontalAccuracy = fix.horizontalAccuracy
        }

        do {
            try store.add(note)
        } catch {
            await glasses.speak(MemorySpeech.couldNotSave)
            return
        }

        if wantsParkingPhoto {
            if let signText {
                await glasses.speak(MemorySpeech.savedParkingWithSign(signText))
            } else if outcome == .denied {
                await glasses.speak(MemorySpeech.savedParkingWithoutPermission)
            } else {
                // Photo failure is silent: the location (if any) is saved and
                // the wearer still gets a clean confirmation.
                await glasses.speak(MemorySpeech.savedParking)
            }
        } else {
            await glasses.speak(MemorySpeech.rememberedNote(text))
        }
    }

    /// Photo → OCR → tidy. Any failure is nil; the caller decides what to say.
    private func readParkingSign() async -> String? {
        do {
            let photo = try await glasses.capturePhoto()
            let raw = try await signReader.readSignText(from: photo)
            let tidy = ParkingSpeech.signText(fromOCR: raw, maxLength: Self.signTextMaxLength)
            return tidy.isEmpty ? nil : tidy
        } catch {
            return nil
        }
    }

    // MARK: - 9b Recall

    /// On-device only: the newest parking note, the current GPS fix, and
    /// arithmetic. Works with no network at all.
    private func recallParking() async {
        // "Remember the car is in lot B" is saved as a general note; when asked
        // "where's my car" with no parking note, that note is the honest answer.
        guard let note = store.newestParking ?? store.newestGeneralMentioningCar else {
            await glasses.speak(MemorySpeech.noParkingSaved)
            return
        }

        var here: CLLocation?
        if note.hasLocation {
            here = await location.requestFix().fix?.clLocation
        }

        await glasses.speak(ParkingSpeech.recallSentence(for: note, here: here, now: now()))
    }

    private func openDirectionsToCar() async {
        guard let coordinate = store.newestParking?.coordinate else {
            await glasses.speak(MemorySpeech.noCarLocation)
            return
        }
        directions.openWalkingDirections(to: coordinate)
        await glasses.speak(MemorySpeech.openingDirections)
    }

    private func recallGeneral(question: String) async {
        let notes = store.recent(RecallClient.maxNotes)
        guard !notes.isEmpty else {
            await glasses.speak(MemorySpeech.nothingRemembered)
            return
        }

        do {
            let result = try await recall.answer(question: question, notes: notes, now: now(), timeZone: .current)
            let answer = result.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            await glasses.speak(answer.isEmpty ? MemorySpeech.recallUnavailable : answer)
        } catch {
            await glasses.speak(MemorySpeech.recallUnavailable)
        }
    }

    // MARK: - 9c Forget

    private func forgetLastParking() async {
        guard let note = store.newestParking else {
            await glasses.speak(MemorySpeech.noParkingToForget)
            return
        }
        await forget(note)
    }

    private func forgetLast() async {
        guard let note = store.newest else {
            await glasses.speak(MemorySpeech.nothingToForget)
            return
        }
        await forget(note)
    }

    private func forget(_ note: MemoryNote) async {
        do {
            try store.remove(id: note.id)
        } catch {
            await glasses.speak(MemorySpeech.couldNotForget)
            return
        }
        await glasses.speak(MemorySpeech.forgot(note))
    }

    private func requestForgetAll() async {
        guard !store.notes.isEmpty else {
            await glasses.speak(MemorySpeech.nothingRemembered)
            return
        }
        forgetAllRequestedAt = now()
        await glasses.speak(MemorySpeech.confirmForgetAll)
    }

    private func confirmForgetAll() async {
        defer { forgetAllRequestedAt = nil }
        guard let requestedAt = forgetAllRequestedAt,
              now().timeIntervalSince(requestedAt) <= Self.forgetAllConfirmationWindow else {
            await glasses.speak(MemorySpeech.nothingToConfirm)
            return
        }

        let count = store.notes.count
        do {
            try store.removeAll()
        } catch {
            await glasses.speak(MemorySpeech.couldNotForget)
            return
        }
        await glasses.speak(MemorySpeech.forgotEverything(count: count))
    }
}
