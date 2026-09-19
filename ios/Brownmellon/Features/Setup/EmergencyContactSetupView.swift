import SwiftUI

/// Caregiver-facing screen — configure who "daughter", "son", etc. call,
/// and place a call directly for testing (PRD § Feature 6).
struct EmergencyContactSetupView: View {
    @StateObject private var viewModel: EmergencyContactSetupViewModel

    init(store: SecureLocalStore) {
        _viewModel = StateObject(wrappedValue: EmergencyContactSetupViewModel(store: store))
    }

    var body: some View {
        Form {
            Section("Add a contact") {
                TextField("Relation (e.g. daughter)", text: $viewModel.draftRelation)
                TextField("Phone number", text: $viewModel.draftPhoneNumber)
                    .keyboardType(.phonePad)
                Button("Add") { viewModel.addContact() }
                    .disabled(
                        viewModel.draftRelation.trimmingCharacters(in: .whitespaces).isEmpty
                            || viewModel.draftPhoneNumber.trimmingCharacters(in: .whitespaces).isEmpty
                    )
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
