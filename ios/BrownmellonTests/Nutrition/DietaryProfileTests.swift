import XCTest
@testable import Brownmellon

/// The caregiver's profile: defaults from standard guidance, round-trips
/// through `SecureLocalStore` under the documented key, and the Setup view
/// model persists every edit.
@MainActor
final class DietaryProfileTests: XCTestCase {
    func testDefaultsMatchThePRD() {
        let profile = DietaryProfile()
        XCTAssertTrue(profile.isEmpty)
        XCTAssertEqual(profile.sodiumDailyLimitMg, 1500)
        XCTAssertEqual(profile.carbsPerMealG, 45)
        XCTAssertEqual(profile.saturatedFatDailyLimitG, 13)
        XCTAssertEqual(profile.potassiumDailyLimitMg, 2000)
        XCTAssertEqual(Allergen.allCases.count, 9, "the FDA nine")
    }

    func testIsEmptyIgnoresBlankAvoidWords() {
        var profile = DietaryProfile()
        profile.avoidIngredients = ["  ", ""]
        XCTAssertTrue(profile.isEmpty)
        profile.avoidIngredients = ["grapefruit"]
        XCTAssertFalse(profile.isEmpty)
    }

    func testRoundTripsThroughTheStore() throws {
        var profile = DietaryProfile.lowSodiumPeanutAllergy
        profile.sodiumDailyLimitMg = 2000
        profile.avoidIngredients = ["Grapefruit", "aspartame"]
        profile.allergens.insert(.treeNuts)

        let store = MockSecureLocalStore()
        try store.save(profile, forKey: DietaryProfile.storageKey)
        let loaded: DietaryProfile? = try store.load(forKey: "dietaryProfile")
        XCTAssertEqual(loaded, profile)
    }

    func testDecodesAPartialProfileWithDefaults() throws {
        let data = Data(#"{"lowSodium":true,"allergens":["peanuts"]}"#.utf8)
        let profile = try JSONDecoder().decode(DietaryProfile.self, from: data)
        XCTAssertTrue(profile.lowSodium)
        XCTAssertEqual(profile.sodiumDailyLimitMg, 1500)
        XCTAssertEqual(profile.allergens, [.peanuts])
        XCTAssertFalse(profile.carbAware)
    }

    func testSetupViewModelPersistsEveryEdit() throws {
        let store = MockSecureLocalStore()
        let vm = DietSetupViewModel(store: store)
        XCTAssertTrue(vm.profile.isEmpty)

        vm.profile.lowSodium = true
        vm.profile.sodiumDailyLimitMg = 1200
        vm.setAllergen(.peanuts, isOn: true)
        vm.draftAvoidWord = " grapefruit "
        vm.addAvoidWord()
        vm.draftAvoidWord = "Grapefruit"
        vm.addAvoidWord()   // duplicate, ignored

        let saved: DietaryProfile? = try store.load(forKey: DietaryProfile.storageKey)
        let expected = try XCTUnwrap(saved)
        XCTAssertTrue(expected.lowSodium)
        XCTAssertEqual(expected.sodiumDailyLimitMg, 1200)
        XCTAssertEqual(expected.allergens, [.peanuts])
        XCTAssertEqual(expected.avoidIngredients, ["grapefruit"])
        XCTAssertEqual(vm.draftAvoidWord, "")
        XCTAssertNil(vm.lastError)

        vm.setAllergen(.peanuts, isOn: false)
        vm.removeAvoidWords(at: IndexSet(integer: 0))
        let afterRemoval: DietaryProfile? = try store.load(forKey: DietaryProfile.storageKey)
        XCTAssertEqual(afterRemoval?.allergens, [])
        XCTAssertEqual(afterRemoval?.avoidIngredients, [])
    }

    func testSetupViewModelLoadsTheSavedProfile() throws {
        let store = MockSecureLocalStore()
        try store.save(DietaryProfile.lowSodiumPeanutAllergy, forKey: DietaryProfile.storageKey)
        let vm = DietSetupViewModel(store: store)
        XCTAssertEqual(vm.profile, .lowSodiumPeanutAllergy)
    }
}
