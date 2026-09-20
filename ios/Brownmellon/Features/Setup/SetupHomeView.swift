import SwiftUI

/// Caregiver Setup menu — the Setup tab's root. Each caregiver-facing
/// settings screen is one `NavigationLink` here; v2 feature agents add
/// exactly one line each (diet profile, sound alerts, …), directly below
/// the existing link so the merges are adjacent-line conflicts only.
struct SetupHomeView: View {
    let store: SecureLocalStore

    var body: some View {
        List {
            NavigationLink("Emergency Contacts") {
                EmergencyContactSetupView(store: store)
            }
            NavigationLink("Diet") { DietSetupView(store: store) }
        }
        .navigationTitle("Setup")
    }
}
