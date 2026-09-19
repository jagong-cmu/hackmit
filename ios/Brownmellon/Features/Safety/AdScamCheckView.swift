import SwiftUI

/// Multimodal Feature 5 screen. Low risk means only that no obvious warning
/// signs were found; the UI never presents it as a green “safe” confirmation.
struct AdScamCheckView: View {
    @StateObject private var viewModel: AdScamCheckViewModel

    init(glasses: GlassesSession, router: VoiceCommandRouter? = nil) {
        _viewModel = StateObject(
            wrappedValue: AdScamCheckViewModel(glasses: glasses, router: router)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Check an Advertisement")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("The photo is checked for scam warning signs in both its words and visual content.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                actionArea
                resultArea
            }
            .padding()
        }
        .navigationTitle("Check an Ad")
    }

    @ViewBuilder
    private var actionArea: some View {
        switch viewModel.state {
        case .idle, .failed, .completed:
            Button {
                Task { await viewModel.checkAd() }
            } label: {
                Label("Check an ad", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Takes one still photo and checks it for scam warning signs")

        case .capturing:
            ProgressView("Taking one photo…")
                .accessibilityLabel("Taking one photo")

        case .checking:
            ProgressView("Analyzing the ad and checking selected claims…")
                .accessibilityLabel("Analyzing the advertisement and checking selected claims")
        }
    }

    @ViewBuilder
    private var resultArea: some View {
        switch viewModel.state {
        case .completed(let result):
            resultCard(result)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text("The check could not be completed.")
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
        default:
            EmptyView()
        }
    }

    private func resultCard(_ result: ScamCheckBackendClient.Result) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(riskLabel(result.riskLevel), systemImage: riskIcon(result.riskLevel))
                .font(.title3.bold())
                .foregroundStyle(riskColor(result.riskLevel))
                .accessibilityLabel("Risk level: \(riskLabel(result.riskLevel))")

            Text(result.spokenSummary)
                .font(.body)

            evidenceSection(result)
            verificationSection(result)
            aiSection(result.aiAppearance)

            VStack(alignment: .leading, spacing: 6) {
                Text("Recommended next action")
                    .font(.headline)
                Text(result.safeAction)
            }
            .accessibilityElement(children: .combine)

            if !result.extractedText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Visible text")
                        .font(.headline)
                    Text(result.extractedText)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func evidenceSection(_ result: ScamCheckBackendClient.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Observed warning signs")
                .font(.headline)
            if result.observedSignals.isEmpty {
                Text("No specific warning signs were observed.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(result.observedSignals, id: \.self) { signal in
                    Label(signal, systemImage: "exclamationmark.circle")
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func verificationSection(_ result: ScamCheckBackendClient.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Online verification")
                .font(.headline)
            Text(verificationSummary(for: result))
                .foregroundStyle(.secondary)

            ForEach(result.verifiedFindings) { finding in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(findingStatus(finding.status)): \(finding.claim)")
                        .font(.body)
                    if let url = URL(string: finding.sourceURL), url.scheme?.lowercased() == "https" {
                        Link(finding.sourceTitle, destination: url)
                            .font(.callout)
                            .accessibilityLabel("Source: \(finding.sourceTitle)")
                    } else {
                        Text(finding.sourceTitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func aiSection(_ appearance: ScamCheckBackendClient.AIAppearance) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI-origin note")
                .font(.headline)
            switch appearance {
            case .possible:
                Text("The ad has possible AI-looking characteristics. That is not proof of its origin and did not by itself determine scam risk.")
            case .unknown:
                Text("The ad's origin could not be determined. AI appearance and scam risk are separate judgments.")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func riskLabel(_ risk: ScamCheckBackendClient.Risk) -> String {
        switch risk {
        case .high: return "High scam risk"
        case .medium: return "Medium scam risk"
        case .low: return "Low observed risk"
        case .unknown: return "Risk unknown"
        }
    }

    private func riskIcon(_ risk: ScamCheckBackendClient.Risk) -> String {
        switch risk {
        case .high: return "exclamationmark.triangle.fill"
        case .medium: return "exclamationmark.circle.fill"
        case .low: return "minus.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    private func riskColor(_ risk: ScamCheckBackendClient.Risk) -> Color {
        switch risk {
        case .high: return .red
        case .medium: return .orange
        case .low: return .blue
        case .unknown: return .secondary
        }
    }

    private func verificationSummary(for result: ScamCheckBackendClient.Result) -> String {
        if !result.webVerificationAvailable {
            return "Online verification was unavailable. The assessment above is based on the photo only."
        }
        if result.verifiedFindings.isEmpty {
            return "No independently verifiable source was found for the selected ad details."
        }
        return "The selected ad details were checked against independently found sources."
    }

    private func findingStatus(_ status: ScamCheckBackendClient.VerificationStatus) -> String {
        switch status {
        case .supports: return "Supports"
        case .contradicts: return "Contradicts"
        case .unresolved: return "Unresolved"
        }
    }
}
