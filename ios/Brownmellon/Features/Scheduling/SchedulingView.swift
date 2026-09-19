import SwiftUI

/// Features 1–2 (voice scheduling/reminders + daily briefing). Unlike
/// Vision's manual-button screens, the real trigger here is the wake word
/// itself — "Hey Dojo" — so this screen is mostly a status display. The
/// text field below is a Simulator/demo stand-in for actually saying it
/// out loud (`SchedulingCoordinator.handle` is explicitly designed for
/// this — see its doc comment).
struct SchedulingView: View {
    @StateObject private var viewModel: SchedulingViewModel

    init(glasses: GlassesSession, calendar: CalendarService, backendBaseURL: URL, router: VoiceCommandRouter) {
        _viewModel = StateObject(
            wrappedValue: SchedulingViewModel(
                glasses: glasses,
                calendar: calendar,
                backendBaseURL: backendBaseURL,
                router: router
            )
        )
    }

    var body: some View {
        VStack(spacing: 20) {
            Label(
                viewModel.isListening ? "Listening for “Hey Dojo”" : "Not listening",
                systemImage: viewModel.isListening ? "mic.fill" : "mic.slash"
            )
            .font(.headline)
            .foregroundStyle(viewModel.isListening ? .green : .secondary)

            if let response = viewModel.lastResponse {
                Text(response)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("No mic on Simulator — type what you'd say instead:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Hey Dojo, remind me to…", text: $viewModel.draftCommand)
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
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }
}
