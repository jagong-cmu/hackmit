import SwiftUI

/// Manual-trigger scaffold UI for Feature 4. Same caveat as
/// AppointmentCardScanView — voice trigger comes from Workstream A later.
struct ReadToMeView: View {
    @StateObject private var viewModel: ReadToMeViewModel

    init(glasses: GlassesSession) {
        _viewModel = StateObject(wrappedValue: ReadToMeViewModel(glasses: glasses))
    }

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
