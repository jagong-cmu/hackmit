import Foundation

/// A caregiver-configured relation -> phone number mapping (PRD § Feature 6).
/// 911 is always available as a target and isn't stored here — see
/// `EmergencyCallService`.
struct EmergencyContact: Codable, Identifiable, Equatable {
    var id: String
    /// e.g. "daughter" — what the wearer would say to reach this person.
    var relation: String
    var phoneNumber: String

    init(id: String = UUID().uuidString, relation: String, phoneNumber: String) {
        self.id = id
        self.relation = relation
        self.phoneNumber = phoneNumber
    }
}
