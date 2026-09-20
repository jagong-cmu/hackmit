import Foundation

/// The caregiver-facing rows of the Sound Alerts table (PRD-sound-alerts § 8a).
/// Declared in priority order: an announcement suppresses same-or-lower
/// priority labels for a moment, and Safety is never suppressed by anything.
enum SoundGroup: String, Codable, CaseIterable, Identifiable, Sendable {
    case safety
    case someoneHere = "someone_here"
    case phone
    case kitchen
    case ambient

    var id: String { rawValue }

    /// Higher wins. Safety > Someone's here > Phone > Kitchen > Ambient.
    var priority: Int {
        SoundGroup.allCases.count - (SoundGroup.allCases.firstIndex(of: self) ?? 0)
    }

    /// Everything but Ambient is announced out of the box.
    var isOnByDefault: Bool { self != .ambient }

    var title: String {
        switch self {
        case .safety: return "Safety"
        case .someoneHere: return "Someone's here"
        case .phone: return "Phone"
        case .kitchen: return "Kitchen"
        case .ambient: return "Ambient"
        }
    }
}

/// One classifier label the feature knows how to talk about.
struct SoundCatalogEntry: Equatable, Sendable {
    /// Exactly as `SNClassifySoundRequest.knownClassifications` spells it —
    /// `SoundCatalogTests` fails the build's tests if any of these drift.
    let identifier: String
    let group: SoundGroup
    /// Product copy spoken through the glasses when the sound is announced.
    let spokenPhrase: String
    /// Short name for notifications and the Setup screen ("Smoke alarm").
    let displayName: String
    /// Noun phrase for "…it sounded like a doorbell."
    let description: String
}

/// label → (group, spoken phrase, default on/off). The single place the
/// classifier's vocabulary is mapped onto what the wearer hears.
///
/// Every identifier below was checked against
/// `SNClassifySoundRequest(classifierIdentifier: .version1).knownClassifications`
/// (303 labels) during development. Notably the PRD's guess `doorbell` does
/// not exist — the label is `door_bell`.
enum SoundCatalog {
    static let entries: [SoundCatalogEntry] = [
        // Safety — announced, repeated once, plus haptic + notification.
        SoundCatalogEntry(
            identifier: "smoke_detector", group: .safety,
            spokenPhrase: "I hear a smoke alarm.",
            displayName: "Smoke alarm", description: "a smoke alarm"
        ),
        SoundCatalogEntry(
            identifier: "glass_breaking", group: .safety,
            spokenPhrase: "I heard glass breaking.",
            displayName: "Glass breaking", description: "glass breaking"
        ),

        // Someone's here
        SoundCatalogEntry(
            identifier: "door_bell", group: .someoneHere,
            spokenPhrase: "Someone's at the door — I heard the doorbell.",
            displayName: "Doorbell", description: "a doorbell"
        ),
        SoundCatalogEntry(
            identifier: "knock", group: .someoneHere,
            spokenPhrase: "I heard knocking.",
            displayName: "Knocking", description: "knocking"
        ),

        // Phone
        SoundCatalogEntry(
            identifier: "telephone_bell_ringing", group: .phone,
            spokenPhrase: "Your phone is ringing.",
            displayName: "Phone ringing", description: "a phone ringing"
        ),
        SoundCatalogEntry(
            identifier: "ringtone", group: .phone,
            spokenPhrase: "Your phone is ringing.",
            displayName: "Phone ringing", description: "a phone ringing"
        ),

        // Kitchen
        SoundCatalogEntry(
            identifier: "microwave_oven", group: .kitchen,
            spokenPhrase: "I heard a kitchen timer.",
            displayName: "Kitchen timer", description: "a kitchen timer"
        ),
        SoundCatalogEntry(
            identifier: "alarm_clock", group: .kitchen,
            spokenPhrase: "I heard an alarm going off.",
            displayName: "Alarm", description: "an alarm going off"
        ),
        SoundCatalogEntry(
            identifier: "boiling", group: .kitchen,
            spokenPhrase: "I heard something boiling.",
            displayName: "Boiling", description: "something boiling"
        ),

        // Ambient — off by default.
        SoundCatalogEntry(
            identifier: "dog_bark", group: .ambient,
            spokenPhrase: "I heard a dog barking.",
            displayName: "Dog barking", description: "a dog barking"
        ),
        SoundCatalogEntry(
            identifier: "baby_crying", group: .ambient,
            spokenPhrase: "I heard a baby crying.",
            displayName: "Baby crying", description: "a baby crying"
        ),
        SoundCatalogEntry(
            identifier: "siren", group: .ambient,
            spokenPhrase: "I heard a siren.",
            displayName: "Siren", description: "a siren"
        ),
        SoundCatalogEntry(
            identifier: "ambulance_siren", group: .ambient,
            spokenPhrase: "I heard a siren.",
            displayName: "Siren", description: "a siren"
        ),
        SoundCatalogEntry(
            identifier: "police_siren", group: .ambient,
            spokenPhrase: "I heard a siren.",
            displayName: "Siren", description: "a siren"
        ),
        SoundCatalogEntry(
            identifier: "fire_engine_siren", group: .ambient,
            spokenPhrase: "I heard a siren.",
            displayName: "Siren", description: "a siren"
        ),
        SoundCatalogEntry(
            identifier: "car_horn", group: .ambient,
            spokenPhrase: "I heard a car horn.",
            displayName: "Car horn", description: "a car horn"
        ),
        SoundCatalogEntry(
            identifier: "water_tap_faucet", group: .ambient,
            spokenPhrase: "I heard water running.",
            displayName: "Water running", description: "water running"
        ),
    ]

    /// Labels the feature must never act on, whatever the confidence: this
    /// feature does not listen to conversation (PRD § Non-goals).
    static let ignoredIdentifiers: Set<String> = ["speech"]

    private static let byIdentifier: [String: SoundCatalogEntry] =
        Dictionary(uniqueKeysWithValues: entries.map { ($0.identifier, $0) })

    static var identifiers: [String] { entries.map(\.identifier) }

    static func entry(for identifier: String) -> SoundCatalogEntry? {
        byIdentifier[identifier]
    }

    static func entries(in group: SoundGroup) -> [SoundCatalogEntry] {
        entries.filter { $0.group == group }
    }

    /// "Smoke alarm, glass breaking" — the Setup row's subtitle.
    static func summary(of group: SoundGroup) -> String {
        var seen: [String] = []
        for entry in entries(in: group) where !seen.contains(entry.displayName) {
            seen.append(entry.displayName)
        }
        return seen.enumerated()
            .map { $0.offset == 0 ? $0.element : $0.element.lowercased() }
            .joined(separator: ", ")
    }
}
