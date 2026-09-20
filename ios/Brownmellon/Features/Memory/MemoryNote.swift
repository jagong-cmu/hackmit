import Foundation
import CoreLocation

/// One thing the wearer asked the glasses to remember (PRD-memory § Data).
///
/// Coordinates are phone-only: `RecallClient` never serializes them, and the
/// parking recall path that uses them runs entirely on-device.
struct MemoryNote: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case parking
        case general
    }

    let id: UUID
    var kind: Kind
    /// What the wearer said with the "remember …" prefix stripped, in the
    /// normalized form the voice pipeline delivers (lowercase, no
    /// punctuation). Empty is allowed for a photo-only parking note.
    var text: String
    /// OCR of the spot marker (parking only), already tidied for speech.
    var signText: String?
    let createdAt: Date
    var latitude: Double?
    var longitude: Double?
    var horizontalAccuracy: Double?

    init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        signText: String? = nil,
        createdAt: Date = Date(),
        latitude: Double? = nil,
        longitude: Double? = nil,
        horizontalAccuracy: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.signText = signText
        self.createdAt = createdAt
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
    }

    var hasLocation: Bool { latitude != nil && longitude != nil }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation? {
        guard let latitude, let longitude else { return nil }
        return CLLocation(latitude: latitude, longitude: longitude)
    }

    /// True when the sign photo produced readable text.
    var hasSignText: Bool {
        guard let signText else { return false }
        return !signText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
