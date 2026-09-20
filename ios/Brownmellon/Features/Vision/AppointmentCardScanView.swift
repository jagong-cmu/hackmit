import SwiftUI

/// Feature 3's screen. "Hey Dojo, scan this" (via `VoiceCommandRouter`) and
/// the button below drive the same shared view model, so a spoken command
/// shows up here as it runs; "yes"/"no" and the two buttons are likewise
/// the same confirm/decline.
struct AppointmentCardScanView: View {
    @ObservedObject var viewModel: AppointmentCardScanViewModel

    var body: some View {
        VStack(spacing: 20) {
            Text("Appointment Card Scanning")
                .font(.headline)

            switch viewModel.state {
            case .idle, .failed, .noResult, .saved:
                Button("Scan a card") {
                    Task { await viewModel.scan() }
                }
                .buttonStyle(.borderedProminent)

            case .capturing:
                ProgressView("Taking photo…")
            case .parsing:
                ProgressView("Reading the card…")

            case .awaitingConfirmation(let title, let start, let location):
                VStack(spacing: 12) {
                    Text(title).font(.title3.bold())
                    Text(start.formatted(date: .abbreviated, time: .shortened))
                    if let location {
                        Text(location).foregroundStyle(.secondary)
                    }
                    Text("Say “yes” or “no”, or tap:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Add to calendar") { Task { await viewModel.confirm() } }
                            .buttonStyle(.borderedProminent)
                        Button("Never mind") { Task { await viewModel.decline() } }
                    }
                }
            }

            statusFooter
        }
        .padding()
    }

    @ViewBuilder
    private var statusFooter: some View {
        switch viewModel.state {
        case .saved(let event):
            Text("Saved: \(event.title)").foregroundStyle(.green)
        case .noResult:
            Text("No date/time found on that card — try again.").foregroundStyle(.orange)
        case .failed(let message):
            Text("Error: \(message)").foregroundStyle(.red)
        default:
            EmptyView()
        }
    }
}
