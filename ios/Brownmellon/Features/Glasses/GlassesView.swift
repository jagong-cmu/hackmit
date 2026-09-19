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
                if session.devices.isEmpty {
                    Text("No glasses detected — open the hinges and check Bluetooth.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.devices, id: \.self) { device in
                        Label(String(describing: device), systemImage: "eyeglasses")
                    }
                }
            }

            Section("Microphone") {
                LabeledContent("Wake-word listener", value: session.isListening ? "Listening" : "Off")
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
}
