import SwiftUI

/// Feature 4's screen. "Hey Dojo, read this to me" (via `VoiceCommandRouter`)
/// and the button below drive the same shared view model.
struct ReadToMeView: View {
    @ObservedObject var viewModel: ReadToMeViewModel

    var body: some View {
        VStack(spacing: 20) {
            Text("Read This To Me")
                .font(.headline)

            switch viewModel.state {
            case .idle, .failed, .done:
                Button("Read something") {
                    Task { await viewModel.readThisToMe() }
                }
                .buttonStyle(.borderedProminent)
            case .capturing:
                ProgressView("Taking photo…")
            case .reading:
                ProgressView("Reading…")
            }

            switch viewModel.state {
            case .done(let text):
                ScrollView {
                    Text(text).padding()
                }
            case .failed(let message):
                Text("Error: \(message)").foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
        .padding()
    }
}
