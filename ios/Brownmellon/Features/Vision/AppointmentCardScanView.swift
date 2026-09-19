import SwiftUI

/// Manual-trigger scaffold UI for Feature 3. The real trigger is voice
/// ("Hey Brownmellon, scan this") via Workstream A's keyword router —
/// this button stands in for that until the two workstreams merge.
struct AppointmentCardScanView: View {
    @StateObject private var viewModel: AppointmentCardScanViewModel

    init(glasses: GlassesSession, calendar: CalendarService) {
        _viewModel = StateObject(wrappedValue: AppointmentCardScanViewModel(glasses: glasses, calendar: calendar))
    }

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
