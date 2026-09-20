import SwiftUI

/// Memory tab (PRD-memory § 9d): the notes the glasses are holding, newest
/// first, plus the Simulator "type what you'd say" field. The product is the
/// voice path — this screen exists to see and demo what it did.
struct MemoryView: View {
    @ObservedObject var viewModel: MemoryViewModel

    var body: some View {
        NavigationStack {
            List {
                if let response = viewModel.lastResponse, !response.isEmpty {
                    Section("Glasses said") {
                        Text(response)
                    }
                }

                Section {
                    if viewModel.notes.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.notes) { note in
                            MemoryNoteRow(note: note) {
                                viewModel.openDirections(to: note)
                            }
                        }
                        .onDelete { offsets in
                            viewModel.delete(at: offsets)
                        }
                    }
                } header: {
                    Text("Notes")
                } footer: {
                    if let error = viewModel.storeError {
                        Text(error).foregroundStyle(.red)
                    } else if !viewModel.notes.isEmpty, !viewModel.notesPersist {
                        Text("Simulator keeps notes in memory only — they reset when the app relaunches.")
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No mic on Simulator — type what you'd say after “Hey Dojo”:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("remember I parked in section B", text: $viewModel.draftCommand)
                                .textFieldStyle(.roundedBorder)
                                .submitLabel(.send)
                                .onSubmit { Task { await viewModel.tryCommand() } }
                            Button("Try it") {
                                Task { await viewModel.tryCommand() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.draftCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Memory")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing remembered yet.")
                .font(.headline)
            Text("Try “remember I parked in section B”, then “where did I park?”")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !viewModel.notesPersist {
                Text("On Simulator, notes live in memory only and reset when the app relaunches. On a phone they're kept in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MemoryNoteRow: View {
    let note: MemoryNote
    let onDirections: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: note.kind == .parking ? "car.fill" : "note.text")
                .foregroundStyle(note.kind == .parking ? .blue : .secondary)
                .frame(width: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(MemoryViewModel.title(for: note))
                HStack(spacing: 6) {
                    Text(MemoryViewModel.subtitle(for: note))
                    if note.hasLocation {
                        Image(systemName: "mappin.and.ellipse")
                            .accessibilityLabel("Location saved")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if note.kind == .parking, note.hasLocation {
                    Button("Directions", systemImage: "figure.walk", action: onDirections)
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
