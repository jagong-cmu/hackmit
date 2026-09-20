import Foundation

/// Caregiver Setup Mode for Feature 6 (PRD § Feature 6, § Workstream C —
/// "Setup Mode's UI shell is shared" with Feature 5's enrollment flow;
/// this scaffold covers the emergency-contact half). Contacts persist via
/// `SecureLocalStore` — encrypted at rest, never synced (PRD § Platform).
@MainActor
final class EmergencyContactSetupViewModel: ObservableObject {
    private static let storageKey = "emergencyContacts"

    @Published private(set) var contacts: [EmergencyContact] = []
    @Published var draftRelation: String = ""
    @Published var draftPhoneNumber: String = ""
    @Published private(set) var lastError: String?

    private let store: SecureLocalStore

    init(store: SecureLocalStore) {
        self.store = store
        load()
    }

    func load() {
        do {
            contacts = try store.load(forKey: Self.storageKey) ?? []
        } catch {
            lastError = "Couldn't load saved contacts."
        }
    }

    func addContact() {
        let relation = draftRelation.trimmingCharacters(in: .whitespacesAndNewlines)
        let phoneNumber = draftPhoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relation.isEmpty, !phoneNumber.isEmpty else { return }

        contacts.append(EmergencyContact(relation: relation, phoneNumber: phoneNumber))
        draftRelation = ""
        draftPhoneNumber = ""
        persist()
    }

    func removeContact(_ contact: EmergencyContact) {
        contacts.removeAll { $0.id == contact.id }
        persist()
    }

    /// The contact the wearer meant by "call my daughter". Matches on the
    /// configured relation word, ignoring case and the odd plural ("daughters")
    /// — anything looser risks dialing the wrong person in an emergency.
    func contact(matching spoken: String) -> EmergencyContact? {
        let wanted = WakeWordDetector.tokenize(spoken)
        guard !wanted.isEmpty else { return nil }

        func matches(_ contact: EmergencyContact) -> Int? {
            let relation = WakeWordDetector.tokenize(contact.relation)
            guard !relation.isEmpty else { return nil }
            // "daughter" matches "daughter" and "daughters"; a multi-word
            // relation ("my son in law" → "son in law") must appear in order.
            if relation.count == 1 {
                let word = relation[0]
                return wanted.contains { $0 == word || $0 == word + "s" } ? 1 : nil
            }
            return wanted.joined(separator: " ").contains(relation.joined(separator: " ")) ? relation.count : nil
        }

        // Most specific relation wins: "call my son in law" must not dial
        // "son" just because that contact was added first.
        return contacts
            .compactMap { contact in matches(contact).map { (contact, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// Places the call from either trigger — "Hey Dojo, call my daughter"
    /// (via `VoiceCommandRouter`) or the on-screen button. Returns false if
    /// iOS refused to open the dialer (Simulator, or a malformed number), so
    /// the caller can say so instead of claiming a call is on its way.
    @discardableResult
    func callNow(_ contact: EmergencyContact) -> Bool {
        EmergencyCallService.call(contact.phoneNumber)
    }

    @discardableResult
    func call911() -> Bool {
        EmergencyCallService.call(EmergencyCallService.emergencyNumber)
    }

    private func persist() {
        do {
            try store.save(contacts, forKey: Self.storageKey)
        } catch {
            lastError = "Couldn't save that contact."
        }
    }
}
