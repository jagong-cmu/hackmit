import SwiftUI

/// The "Check Food" tab (PRD-food-label § 10e). The product is the voice
/// path — "Hey Dojo, can I eat this?" — so this screen is secondary: a button
/// per mode for Simulator use, the last spoken text, and a collapsible dump of
/// the parsed label for debugging.
struct FoodLabelView: View {
    @ObservedObject var viewModel: FoodLabelViewModel
    @State private var showParsedLabel = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Check Food")
                    .font(.headline)

                Text("Say “Hey Dojo, read this label” or “Hey Dojo, can I eat this?” while holding the package up. On Simulator, the buttons below pick a photo instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                switch viewModel.state {
                case .capturing:
                    ProgressView("Taking photo…")
                case .reading:
                    ProgressView("Reading the label…")
                case .idle, .done, .failed:
                    HStack(spacing: 12) {
                        Button {
                            Task { await viewModel.readLabel() }
                        } label: {
                            Label("Read this label", systemImage: "text.magnifyingglass")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            Task { await viewModel.checkFood() }
                        } label: {
                            Label("Can I eat this?", systemImage: "carrot")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if let spoken = viewModel.lastSpoken {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Last said").font(.caption).foregroundStyle(.secondary)
                        Text(spoken)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                if case .failed(let message) = viewModel.state {
                    Text("Error: \(message)").foregroundStyle(.red).font(.caption)
                }

                if let label = viewModel.lastLabel {
                    DisclosureGroup("Parsed label (debug)", isExpanded: $showParsedLabel) {
                        Text(Self.dump(label))
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                Text("Brownmellon compares the numbers on a food label to the limits set in Setup. It is not medical advice.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }

    /// Pretty JSON of the parsed result, so a demo can show what the model
    /// actually read when a number sounds off.
    static func dump(_ label: FoodLabelResult) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(label), let text = String(data: data, encoding: .utf8) else {
            return String(describing: label)
        }
        return text
    }
}
