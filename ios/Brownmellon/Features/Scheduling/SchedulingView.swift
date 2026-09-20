import SwiftUI

/// Features 1–2 (voice scheduling/reminders + daily briefing). Unlike
/// Vision's manual-button screens, the real trigger here is the wake word
/// itself — "Hey Dojo" — so this screen is mostly a status display. The
/// text field below is a Simulator/demo stand-in for actually saying it
/// out loud (`SchedulingCoordinator.handle` is explicitly designed for
/// this — see its doc comment).
///
/// Listening is owned by the app-wide `VoiceAssistant` and runs for the
/// app's lifetime — this screen neither starts nor stops it.
struct SchedulingView: View {
    @ObservedObject var viewModel: SchedulingViewModel
    private let realGlasses: DATGlassesSession?

    init(viewModel: SchedulingViewModel, glasses: GlassesSession) {
        self.viewModel = viewModel
        realGlasses = glasses as? DATGlassesSession
    }

    var body: some View {
        VStack(spacing: 20) {
            if let realGlasses {
                // On hardware, show what the mic pipeline is actually doing —
                // the view model's own flag only says we *asked* it to listen.
                ListenerStatus(session: realGlasses)
            } else {
                Label(
                    viewModel.isListening ? "Listening for “Hey Dojo”" : "Not listening",
                    systemImage: viewModel.isListening ? "mic.fill" : "mic.slash"
                )
                .font(.headline)
                .foregroundStyle(viewModel.isListening ? .green : .secondary)
            }

            if let response = viewModel.lastResponse {
                Text(response)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text(realGlasses == nil
                     ? "No mic on Simulator — type what you'd say instead:"
                     : "Or type a command to test without speaking:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("remind me to take my pills at 8", text: $viewModel.draftCommand)
                        .textFieldStyle(.roundedBorder)
                    Button("Try it") {
                        Task { await viewModel.tryCommand() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.draftCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding()
    }
}

private struct ListenerStatus: View {
    @ObservedObject var session: DATGlassesSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                session.isListening ? "Listening for “Hey Dojo”" : "Not listening",
                systemImage: session.isListening ? "mic.fill" : "mic.slash"
            )
            .font(.headline)
            .foregroundStyle(session.isListening ? .green : .secondary)

            if let heard = session.lastTranscript, !heard.isEmpty {
                Text("Heard: “\(heard)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else if session.isListening {
                Text("Nothing heard yet — say something.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = session.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
