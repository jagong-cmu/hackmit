import XCTest
import SoundAnalysis
@testable import Brownmellon

/// The catalog is the one place classifier labels are mapped to what the
/// wearer hears. These tests are what enforce PRD-sound-alerts' "don't ship a
/// label this doc guessed": every identifier must be one the built-in
/// classifier actually produces.
final class SoundCatalogTests: XCTestCase {
    func testEveryCatalogIdentifierIsAKnownClassification() throws {
        let known = try SNClassifySoundRequest(classifierIdentifier: .version1).knownClassifications
        XCTAssertFalse(known.isEmpty)
        for identifier in SoundCatalog.identifiers {
            XCTAssertTrue(known.contains(identifier), "\(identifier) is not a label the built-in classifier produces")
        }
    }

    func testPRDGuessedDoorbellLabelDoesNotExistAndIsNotUsed() throws {
        // The PRD guessed `doorbell`; the classifier's label is `door_bell`.
        let known = try SNClassifySoundRequest(classifierIdentifier: .version1).knownClassifications
        XCTAssertFalse(known.contains("doorbell"))
        XCTAssertNil(SoundCatalog.entry(for: "doorbell"))
        XCTAssertEqual(SoundCatalog.entry(for: "door_bell")?.group, .someoneHere)
    }

    func testIdentifiersAreUnique() {
        XCTAssertEqual(Set(SoundCatalog.identifiers).count, SoundCatalog.identifiers.count)
    }

    func testSpeechIsIgnoredAndNeverInTheCatalog() {
        XCTAssertTrue(SoundCatalog.ignoredIdentifiers.contains("speech"))
        XCTAssertNil(SoundCatalog.entry(for: "speech"))
    }

    func testEveryGroupHasSoundsAndTableDefaults() {
        for group in SoundGroup.allCases {
            XCTAssertFalse(SoundCatalog.entries(in: group).isEmpty, "\(group) has no sounds")
        }
        XCTAssertTrue(SoundGroup.safety.isOnByDefault)
        XCTAssertTrue(SoundGroup.someoneHere.isOnByDefault)
        XCTAssertTrue(SoundGroup.phone.isOnByDefault)
        XCTAssertTrue(SoundGroup.kitchen.isOnByDefault)
        XCTAssertFalse(SoundGroup.ambient.isOnByDefault)
    }

    func testSafetyOutranksEveryOtherGroup() {
        for group in SoundGroup.allCases where group != .safety {
            XCTAssertGreaterThan(SoundGroup.safety.priority, group.priority)
        }
        XCTAssertGreaterThan(SoundGroup.phone.priority, SoundGroup.ambient.priority)
    }

    func testSpokenPhrasesAreTheProductCopy() {
        XCTAssertEqual(SoundCatalog.entry(for: "smoke_detector")?.spokenPhrase, "I hear a smoke alarm.")
        XCTAssertEqual(SoundCatalog.entry(for: "door_bell")?.spokenPhrase, "Someone's at the door — I heard the doorbell.")
        XCTAssertEqual(SoundCatalog.entry(for: "knock")?.spokenPhrase, "I heard knocking.")
        XCTAssertEqual(SoundCatalog.entry(for: "telephone_bell_ringing")?.spokenPhrase, "Your phone is ringing.")
        XCTAssertEqual(SoundCatalog.entry(for: "ringtone")?.spokenPhrase, "Your phone is ringing.")
        XCTAssertEqual(SoundCatalog.entry(for: "microwave_oven")?.spokenPhrase, "I heard a kitchen timer.")
        XCTAssertEqual(SoundCatalog.entry(for: "alarm_clock")?.spokenPhrase, "I heard an alarm going off.")
        XCTAssertEqual(SoundCatalog.entry(for: "dog_bark")?.spokenPhrase, "I heard a dog barking.")
    }

    func testEveryEntryHasCompleteCopy() {
        for entry in SoundCatalog.entries {
            XCTAssertFalse(entry.spokenPhrase.isEmpty, entry.identifier)
            XCTAssertTrue(entry.spokenPhrase.hasSuffix("."), "\(entry.identifier): spoken phrases are sentences")
            XCTAssertFalse(entry.displayName.isEmpty, entry.identifier)
            XCTAssertFalse(entry.description.isEmpty, entry.identifier)
        }
    }

    func testGroupSummaryReadsNaturally() {
        XCTAssertEqual(SoundCatalog.summary(of: .safety), "Smoke alarm, glass breaking")
        XCTAssertEqual(SoundCatalog.summary(of: .someoneHere), "Doorbell, knocking")
        XCTAssertEqual(SoundCatalog.summary(of: .phone), "Phone ringing")
    }
}
