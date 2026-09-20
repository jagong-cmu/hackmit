import SwiftUI

/// Caregiver-facing screen — configure who "daughter", "son", etc. call,
/// and place a call directly for testing (PRD § Feature 6). The relation
/// word entered here is exactly what the wearer says: "Hey Dojo, call my
/// daughter" (via `VoiceCommandRouter`) dials the same number as the button.
struct EmergencyContactSetupView: View {
    @ObservedObject var viewModel: EmergencyContactSetupViewModel

    var body: some View {
        Form {
            Section {
                TextField("Relation (e.g. daughter)", text: $viewModel.draftRelation)
                TextField("Phone number", text: $viewModel.draftPhoneNumber)
                    .keyboardType(.phonePad)
                Button("Add") { viewModel.addContact() }
                    .disabled(
                        viewModel.draftRelation.trimmingCharacters(in: .whitespaces).isEmpty
                            || viewModel.draftPhoneNumber.trimmingCharacters(in: .whitespaces).isEmpty
                    )
            } header: {
                Text("Add a contact")
            } footer: {
                Text("The wearer says “\(WakeWordDetector.phrase), call my daughter” to reach whoever is saved as “daughter”. “\(WakeWordDetector.phrase), call 911” always works. iOS asks for one tap on the phone before any call connects.")
            }

            Section("Configured contacts") {
                if viewModel.contacts.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
                ForEach(viewModel.contacts) { contact in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(contact.relation.capitalized).font(.body)
                            Text(contact.phoneNumber).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Call") { viewModel.callNow(contact) }
                            .buttonStyle(.bordered)
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet { viewModel.removeContact(viewModel.contacts[index]) }
                }
            }

            Section {
                Button(role: .destructive) {
                    viewModel.call911()
                } label: {
                    Label("Call 911", systemImage: "phone.fill")
                }
            }

            if let error = viewModel.lastError {
                Text(error).foregroundStyle(.red)
            }
        }
        .navigationTitle("Emergency Contacts")
    }
}
