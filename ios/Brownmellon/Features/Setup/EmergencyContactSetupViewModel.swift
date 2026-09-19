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

    /// Manual trigger for this scaffold — see `EmergencyCallService` for
    /// why the real dedicated-phrase trigger isn't wired up yet.
    func callNow(_ contact: EmergencyContact) {
        EmergencyCallService.call(contact.phoneNumber)
    }

    func call911() {
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
