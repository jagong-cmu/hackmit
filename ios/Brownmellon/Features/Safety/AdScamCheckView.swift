import SwiftUI

/// Feature 5's screen. "Hey Dojo, check this ad" (via `VoiceCommandRouter`)
/// and the button below drive the same shared view model.
struct AdScamCheckView: View {
    @ObservedObject var viewModel: AdScamCheckViewModel

    var body: some View {
        VStack(spacing: 20) {
            Text("Check This Ad")
                .font(.headline)

            switch viewModel.state {
            case .idle, .failed, .done, .unreadable:
                Button("Check an ad") {
                    Task { await viewModel.checkAd() }
                }
                .buttonStyle(.borderedProminent)
            case .capturing:
                ProgressView("Taking photo…")
            case .checking:
                ProgressView("Checking…")
            }

            switch viewModel.state {
            case .done(let result):
                VStack(alignment: .leading, spacing: 8) {
                    Label(riskLabel(result.scamRisk), systemImage: riskIcon(result.scamRisk))
                        .font(.title3.bold())
                        .foregroundStyle(riskColor(result.scamRisk))

                    if !result.cues.isEmpty {
                        Text("Why:").font(.caption).foregroundStyle(.secondary)
                        ForEach(result.cues, id: \.self) { cue in
                            Text("• \(cue)").font(.caption)
                        }
                    }

                    Text(result.safeAction)
                        .padding(.top, 4)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            case .unreadable(let message):
                VStack(alignment: .leading, spacing: 8) {
                    // Neutral, never green — this is "I couldn't read it",
                    // not "it's fine".
                    Label("Couldn't read this ad", systemImage: "questionmark.circle.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.secondary)

                    Text(message).padding(.top, 4)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            case .failed(let message):
                Text("Error: \(message)").foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
        .padding()
    }

    private func riskLabel(_ risk: ScamCheckBackendClient.Risk) -> String {
        switch risk {
        case .high: return "High risk"
        case .medium: return "Some risk"
        case .low: return "Low risk"
        }
    }

    private func riskIcon(_ risk: ScamCheckBackendClient.Risk) -> String {
        switch risk {
        case .high: return "exclamationmark.triangle.fill"
        case .medium: return "exclamationmark.circle.fill"
        case .low: return "checkmark.circle.fill"
        }
    }

    private func riskColor(_ risk: ScamCheckBackendClient.Risk) -> Color {
        switch risk {
        case .high: return .red
        case .medium: return .orange
        case .low: return .green
        }
    }
}
