import SwiftUI

/// Manual-trigger scaffold UI for Feature 5, same caveat as Vision's
/// screens — voice trigger comes once Workstream A's router covers it.
struct AdScamCheckView: View {
    @StateObject private var viewModel: AdScamCheckViewModel

    init(glasses: GlassesSession) {
        _viewModel = StateObject(wrappedValue: AdScamCheckViewModel(glasses: glasses))
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Check This Ad")
                .font(.headline)

            switch viewModel.state {
            case .idle, .failed, .done:
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
