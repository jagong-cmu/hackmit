import SwiftUI

/// Caregiver Setup menu — the Setup tab's root. Each caregiver-facing
/// settings screen is one `NavigationLink` here.
struct SetupHomeView: View {
    let store: SecureLocalStore

    var body: some View {
        List {
            NavigationLink("Emergency Contacts") {
                EmergencyContactSetupView(store: store)
            }
            NavigationLink("Diet") { DietSetupView(store: store) }
            NavigationLink("Sound Alerts") { SoundAlertSettingsView() }
        }
        .navigationTitle("Setup")
    }
}
