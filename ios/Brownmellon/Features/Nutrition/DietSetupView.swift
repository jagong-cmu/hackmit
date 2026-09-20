import SwiftUI

/// Caregiver-facing screen — the diet the wearer has been told to follow,
/// reached from Setup → "Diet" (PRD-food-label § 10a). Each restriction is a
/// switch with an editable limit where one applies; the defaults come from
/// standard guidance so a caregiver can just flip the switch.
struct DietSetupView: View {
    @StateObject private var viewModel: DietSetupViewModel

    init(store: SecureLocalStore) {
        _viewModel = StateObject(wrappedValue: DietSetupViewModel(store: store))
    }

    var body: some View {
        Form {
            Section("Limits") {
                Toggle("Low sodium", isOn: $viewModel.profile.lowSodium)
                if viewModel.profile.lowSodium {
                    LimitField(title: "Daily sodium limit", unit: "mg", value: $viewModel.profile.sodiumDailyLimitMg)
                }

                Toggle("Diabetes / carb-aware", isOn: $viewModel.profile.carbAware)
                if viewModel.profile.carbAware {
                    LimitField(title: "Carbs per meal", unit: "g", value: $viewModel.profile.carbsPerMealG)
                }

                Toggle("Low saturated fat", isOn: $viewModel.profile.lowSaturatedFat)
                if viewModel.profile.lowSaturatedFat {
                    LimitField(title: "Daily saturated fat limit", unit: "g", value: $viewModel.profile.saturatedFatDailyLimitG)
                }

                Toggle("Low potassium (kidney)", isOn: $viewModel.profile.lowPotassium)
                if viewModel.profile.lowPotassium {
                    LimitField(title: "Daily potassium limit", unit: "mg", value: $viewModel.profile.potassiumDailyLimitMg)
                }
            }

            Section {
                Toggle("Gluten-free", isOn: $viewModel.profile.glutenFree)
            } footer: {
                Text("Checks the ingredients for wheat, barley, rye, malt and other gluten grains. A “gluten-free” claim printed on the package overrides.")
            }

            Section("Allergies") {
                ForEach(Allergen.allCases) { allergen in
                    Toggle(
                        allergen.spokenName.capitalized,
                        isOn: Binding(
                            get: { viewModel.profile.allergens.contains(allergen) },
                            set: { viewModel.setAllergen(allergen, isOn: $0) }
                        )
                    )
                }
            }

            Section {
                HStack {
                    TextField("e.g. grapefruit, aspartame", text: $viewModel.draftAvoidWord)
                        .textInputAutocapitalization(.never)
                        .onSubmit { viewModel.addAvoidWord() }
                    Button("Add") { viewModel.addAvoidWord() }
                        .disabled(viewModel.draftAvoidWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if viewModel.profile.avoidIngredients.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
                ForEach(viewModel.profile.avoidIngredients, id: \.self) { word in
                    Text(word)
                }
                .onDelete { viewModel.removeAvoidWords(at: $0) }
            } header: {
                Text("Ingredients to avoid")
            } footer: {
                Text("Matched against the ingredients list and the product name — useful for drug–food interactions like grapefruit on statins.")
            }

            Section {
                Text("Brownmellon compares the numbers on a food label to the limits you enter here. It is not medical advice — set these from what the doctor recommended.")
                Text("Limits are checked per serving against US Nutrition Facts labels. Labels from other countries (kilojoules, salt instead of sodium, per-100 g columns) may be read incorrectly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = viewModel.lastError {
                Text(error).foregroundStyle(.red)
            }
        }
        .navigationTitle("Diet")
    }
}

/// A labelled numeric field for one limit.
private struct LimitField: View {
    let title: String
    let unit: String
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: $value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
            Text(unit).foregroundStyle(.secondary)
        }
    }
}
