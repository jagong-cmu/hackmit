import SwiftUI

/// Compact strip above the tabs: is the mic on, what was just heard, what
/// the glasses just said. Visible on every screen because voice now works on
/// every screen — the wearer's companion shouldn't have to hunt for the
/// Schedule tab to see whether "Hey Dojo" landed.
struct VoiceStatusBar: View {
    @ObservedObject var router: VoiceCommandRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: router.isListening ? "mic.fill" : "mic.slash")
                    .foregroundStyle(router.isListening ? .green : .secondary)
                Text(statusText)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if router.isBusy {
                    ProgressView().controlSize(.small)
                }
            }

            if let heard = router.lastCommand {
                Text("You: “\(heard)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let response = router.lastResponse {
                Text("Dojo: \(response)")
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var statusText: String {
        if router.isBusy { return "Working on it…" }
        return router.isListening ? "Listening for “\(WakeWordDetector.phrase)”" : "Not listening"
    }
}
