import Foundation
import CoreLocation

/// Turns a saved parking note plus the wearer's current position into the
/// sentences the glasses speak (PRD-memory § 9b). Pure functions — the
/// handler supplies `now` and the current location, so every branch is
/// unit-testable without GPS or a clock.
enum ParkingSpeech {
    static let staleAfter: TimeInterval = 24 * 60 * 60
    static let justNowUnder: TimeInterval = 60
    static let feetPerMeter = 3.28084
    static let metersPerMile = 1609.344

    // MARK: - Recall sentence

    /// Every row of the PRD's recall table, plus the "> 24 h" prefix.
    /// `here` is the wearer's current fix, nil when unavailable.
    static func recallSentence(for note: MemoryNote, here: CLLocation?, now: Date) -> String {
        let elapsed = spokenElapsed(from: note.createdAt, to: now)
        let sign = note.hasSignText ? note.signText : nil
        let text = note.text.trimmingCharacters(in: .whitespaces)

        var distance: String?
        if let here, let car = note.location {
            distance = spokenOffset(from: here, to: car)
        }

        let body: String
        switch (sign, distance, text.isEmpty) {
        case let (sign?, distance?, _):
            body = "You parked \(elapsed). The sign said \(sign). Your car is \(distance)."
        case let (sign?, nil, _):
            body = "You parked \(elapsed). The sign said \(sign)."
        case let (nil, distance?, true):
            body = "You parked \(elapsed), \(distance) of here."
        case let (nil, distance?, false):
            body = "You told me \(elapsed): \(MemorySpeech.spokenNoteText(text)). Your car is \(distance)."
        case (nil, nil, false):
            body = "You told me \(elapsed): \(MemorySpeech.spokenNoteText(text))."
        case (nil, nil, true):
            body = "You parked \(elapsed), but I couldn't read the sign or save the location."
        }

        guard isStale(createdAt: note.createdAt, now: now) else { return body }
        return "This might be old — " + lowercasingFirst(body)
    }

    static func isStale(createdAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(createdAt) > staleAfter
    }

    // MARK: - Elapsed time

    /// "just now" under a minute, otherwise "about two hours ago" — spelled
    /// out, because it is spoken, never shown.
    static func spokenElapsed(from createdAt: Date, to now: Date) -> String {
        let seconds = now.timeIntervalSince(createdAt)
        guard seconds >= justNowUnder else { return "just now" }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        return "about " + formatter.localizedString(for: createdAt, relativeTo: now)
    }

    // MARK: - Distance and direction

    /// "about 300 feet to the northeast"
    static func spokenOffset(from here: CLLocation, to car: CLLocation) -> String {
        let meters = here.distance(from: car)
        let bearing = bearingDegrees(from: here.coordinate, to: car.coordinate)
        return "\(spokenDistance(meters: meters)) to the \(compassPoint(bearingDegrees: bearing))"
    }

    /// Feet (nearest ten) under 1000 ft, otherwise tenths of a mile.
    static func spokenDistance(meters: Double) -> String {
        let feet = meters * feetPerMeter
        if feet < 1000 {
            let rounded = max(10, Int((feet / 10).rounded()) * 10)
            return "about \(rounded) feet"
        }

        let tenths = Int((meters / metersPerMile * 10).rounded())
        let whole = tenths / 10
        let fraction = tenths % 10
        if fraction == 0 {
            return whole == 1 ? "about 1 mile" : "about \(whole) miles"
        }
        return "about \(whole).\(fraction) miles"
    }

    /// Initial bearing from `a` to `b` in degrees clockwise from north, 0 ..< 360.
    static func bearingDegrees(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let deltaLon = (b.longitude - a.longitude) * .pi / 180

        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    static let compassPoints = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]

    /// 8-point compass; each point owns 45° centered on its heading.
    static func compassPoint(bearingDegrees bearing: Double) -> String {
        let normalized = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let index = Int(((normalized + 22.5) / 45).rounded(.down)) % compassPoints.count
        return compassPoints[index]
    }

    // MARK: - Sign text

    /// Tidies raw OCR of a spot marker for speech: line breaks become
    /// pauses, shouting caps become words ("LEVEL 3\nROW F" → "Level 3, Row
    /// F"), and the result is capped so a wall of small print never gets
    /// read back in full.
    static func signText(fromOCR raw: String, maxLength: Int = 120) -> String {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { line in
                line.split(whereSeparator: \.isWhitespace)
                    .map { word -> String in
                        let token = String(word)
                        let letters = token.filter(\.isLetter)
                        let isShouting = letters.count >= 2 && letters == letters.uppercased()
                        return isShouting ? token.capitalized : token
                    }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }

        var joined = lines.joined(separator: ", ")
        if joined.count > maxLength {
            joined = String(joined.prefix(maxLength))
            if let lastSpace = joined.lastIndex(of: " ") {
                joined = String(joined[..<lastSpace])
            }
        }
        return joined.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }

    // MARK: - Helpers

    private static func lowercasingFirst(_ sentence: String) -> String {
        guard let first = sentence.first else { return sentence }
        return first.lowercased() + sentence.dropFirst()
    }
}
