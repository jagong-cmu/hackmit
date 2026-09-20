import Foundation
import Combine

/// Caregiver Setup for the wearer's diet profile (PRD-food-label § 10a).
/// Every edit persists straight away via `SecureLocalStore` under
/// `DietaryProfile.storageKey` — on-device only, never synced, never sent.
@MainActor
final class DietSetupViewModel: ObservableObject {
    @Published var profile: DietaryProfile
    @Published var draftAvoidWord: String = ""
    @Published private(set) var lastError: String?

    private let store: SecureLocalStore
    private var persistence: AnyCancellable?

    init(store: SecureLocalStore) {
        self.store = store
        var loaded = DietaryProfile()
        var loadError: String?
        do {
            if let saved: DietaryProfile = try store.load(forKey: DietaryProfile.storageKey) {
                loaded = saved
            }
        } catch {
            loadError = "Couldn't load the saved diet profile."
        }
        profile = loaded
        lastError = loadError

        // Save on every change after the initial load.
        persistence = $profile
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] profile in self?.persist(profile) }
    }

    func setAllergen(_ allergen: Allergen, isOn: Bool) {
        if isOn {
            profile.allergens.insert(allergen)
        } else {
            profile.allergens.remove(allergen)
        }
    }

    func addAvoidWord() {
        let word = draftAvoidWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        let duplicate = profile.avoidIngredients.contains { $0.compare(word, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if !duplicate {
            profile.avoidIngredients.append(word)
        }
        draftAvoidWord = ""
    }

    func removeAvoidWords(at offsets: IndexSet) {
        profile.avoidIngredients.remove(atOffsets: offsets)
    }

    private func persist(_ profile: DietaryProfile) {
        do {
            try store.save(profile, forKey: DietaryProfile.storageKey)
            lastError = nil
        } catch {
            lastError = "Couldn't save the diet profile."
        }
    }
}
