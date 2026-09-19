import SwiftUI
import MWDATCore

/// Connection screen for the real glasses: one-time registration handoff to
/// the Meta AI app, then live device/permission status. Only shown when the
/// app is running with `DATGlassesSession` (physical device); Simulator
/// builds use the mock and don't need this.
struct GlassesView: View {
    @ObservedObject var session: DATGlassesSession

    var body: some View {
        Form {
            Section("Meta AI registration") {
                LabeledContent("Status", value: statusText)

                switch session.registrationState {
                case .registered:
                    Button("Disconnect from Meta AI", role: .destructive) {
                        Task { await session.disconnect() }
                    }
                case .registering:
                    ProgressView("Waiting for Meta AI…")
                case .available:
                    Button("Connect glasses via Meta AI") {
                        Task { await session.connect() }
                    }
                    .buttonStyle(.borderedProminent)
                case .unavailable:
                    Text("Registration isn't available. Make sure the Meta AI app is installed, the glasses are paired, and Developer Mode is on in Meta AI (Settings → App Info → tap the version 5×).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Glasses") {
                if session.deviceStatuses.isEmpty {
                    Text("No glasses detected — open the hinges and check Bluetooth.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.deviceStatuses) { device in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(device.name, systemImage: "eyeglasses")
                            HStack(spacing: 12) {
                                statusPill(linkText(device.linkState), good: device.linkState == .connected)
                                statusPill(compatText(device.compatibility), good: device.compatibility == .compatible)
                            }
                            .font(.caption)
                        }
                        if device.compatibility == .deviceUpdateRequired {
                            Button("Update glasses firmware in Meta AI") {
                                Task { await session.openFirmwareUpdate() }
                            }
                        }
                    }
                    if !session.deviceStatuses.contains(where: \.isEligible) {
                        Text("A photo needs the glasses to be both Connected and Compatible. If they're Disconnected while worn and open, check Developer Mode is on for these glasses in Meta AI → Settings → your glasses (not just App Info).")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Microphone") {
                LabeledContent("Wake-word listener", value: session.isListening ? "Listening" : "Off")
                if let heard = session.lastTranscript, !heard.isEmpty {
                    LabeledContent("Last heard", value: heard)
                        .lineLimit(2)
                }
                Text("Starts automatically on the Schedule tab. Audio routes over the glasses' Bluetooth link when they're connected as a headset.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let error = session.lastError {
                Section("Last error") {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Glasses")
    }

    private var statusText: String {
        switch session.registrationState {
        case .registered: return "Connected"
        case .registering: return "Registering…"
        case .available: return "Not connected"
        case .unavailable: return "Unavailable"
        }
    }

    private func linkText(_ state: LinkState) -> String {
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        }
    }

    private func compatText(_ compatibility: Compatibility) -> String {
        switch compatibility {
        case .compatible: return "Compatible"
        case .deviceUpdateRequired: return "Firmware update needed"
        case .sdkUpdateRequired: return "SDK update needed"
        case .undefined: return "Checking…"
        @unknown default: return "Unknown"
        }
    }

    private func statusPill(_ text: String, good: Bool) -> some View {
        Text(text)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background((good ? Color.green : Color.orange).opacity(0.2), in: Capsule())
            .foregroundStyle(good ? .green : .orange)
    }
}
