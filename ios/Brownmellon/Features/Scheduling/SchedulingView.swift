import SwiftUI

/// Features 1–2 (voice scheduling/reminders + daily briefing), and the app's
/// voice console. The real trigger for everything is the wake word — "Hey
/// Dojo" — so this screen shows what the mic pipeline is doing and offers a
/// typed stand-in for saying it out loud. The text field runs the *same*
/// `VoiceCommandRouter.handle` path a spoken command does, for any feature:
/// "remind me to take my pills at 8", "scan this", "call my daughter".
struct SchedulingView: View {
    @ObservedObject var router: VoiceCommandRouter
    let datSession: DATGlassesSession?

    @State private var draftCommand = ""

    var body: some View {
        VStack(spacing: 20) {
            // On hardware, show what the mic pipeline is actually doing — the
            // live transcript and any recognizer error. (The router's own flag,
            // in the status bar above, only says we *asked* it to listen.)
            if let datSession {
                ListenerStatus(session: datSession)
            }

            if let response = router.lastResponse {
                Text(response)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Things you can say after “\(WakeWordDetector.phrase)”")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Self.examples, id: \.self) { example in
                    Text("• \(example)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text(datSession == nil
                     ? "No mic on Simulator — type what you'd say instead:"
                     : "Or type a command to test without speaking:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("remind me to take my pills at 8", text: $draftCommand)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit(send)
                    Button("Try it", action: send)
                        .buttonStyle(.borderedProminent)
                        .disabled(draftCommand.trimmingCharacters(in: .whitespaces).isEmpty || router.isBusy)
                }
            }
        }
        .padding()
    }

    private static let examples = [
        "remind me to take my pills at 8",
        "what do I have today",
        "scan this",
        "read this to me",
        "check this ad",
        "call my daughter  /  call 911",
    ]

    private func send() {
        let command = draftCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        draftCommand = ""
        Task { await router.handle(command) }
    }
}

private struct ListenerStatus: View {
    @ObservedObject var session: DATGlassesSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                session.isListening ? "Listening for “\(WakeWordDetector.phrase)”" : "Not listening",
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
