import SwiftUI
import UserNotifications

/// Caregiver Setup → Sound Alerts (PRD-sound-alerts § 8c): a master toggle,
/// one toggle per row of the sounds table, and a plain-language footer. The
/// view model is the app's one `SoundAlertMonitor` (it owns the settings and
/// persists them through `SecureLocalStore`), handed down from
/// `BrownmellonApp` as an environment object so the voice path, the detector
/// and this screen all act on the same instance.
struct SoundAlertSettingsView: View {
    @EnvironmentObject private var monitor: SoundAlertMonitor
    @State private var notificationStatus: UNAuthorizationStatus?
    #if targetEnvironment(simulator)
    @State private var playingDemo: SoundAlertMonitor.DemoSound?
    #endif

    var body: some View {
        Form {
            Section {
                Toggle("Sound alerts", isOn: masterBinding)
                    .disabled(monitor.isMicrophoneDenied)
            } footer: {
                Text(statusText)
            }

            Section("Announce") {
                ForEach(SoundGroup.allCases) { group in
                    Toggle(isOn: groupBinding(group)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title)
                            Text(SoundCatalog.summary(of: group))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!monitor.settings.isEnabled)
                }
            }

            Section {
                notificationRow
            } header: {
                Text("On the phone")
            } footer: {
                Text("Safety sounds also buzz the phone and show a notification with the sound and the time, in case the spoken alert is missed.")
            }

            Section {
                Text(Self.disclaimer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            #if targetEnvironment(simulator)
            demoSection
            #endif
        }
        .navigationTitle("Sound Alerts")
        .task { await refreshNotificationStatus(requestIfEnabled: true) }
    }

    // MARK: - Copy

    static let disclaimer = """
        Sound alerts listen through the glasses' microphone and work entirely on this phone — nothing is recorded or sent anywhere. \
        They are not a substitute for a proper smoke alarm, strobe or bed-shaker, and they only work while the glasses are being worn, \
        the phone is nearby, and the wearer can hear the glasses' speaker.
        """

    private var statusText: String {
        if monitor.isMicrophoneDenied {
            return "Microphone access is off, so sound alerts can't run. Turn it on in Settings → Brownmellon → Microphone."
        }
        if let error = monitor.lastError {
            return error
        }
        if monitor.isRunning {
            return "Listening for the sounds below through the glasses. Announcements are spoken at the wearer's ear."
        }
        return "Off. The wearer will not be told about alarms, the doorbell or the phone."
    }

    // MARK: - Bindings

    private var masterBinding: Binding<Bool> {
        Binding(
            get: { monitor.settings.isEnabled },
            set: { enabled in
                monitor.setEnabled(enabled)
                if enabled {
                    Task { await refreshNotificationStatus(requestIfEnabled: true) }
                }
            }
        )
    }

    private func groupBinding(_ group: SoundGroup) -> Binding<Bool> {
        Binding(
            get: { monitor.settings.enabledGroups.contains(group) },
            set: { monitor.setGroup(group, enabled: $0) }
        )
    }

    // MARK: - Notifications

    @ViewBuilder
    private var notificationRow: some View {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            Label("Notifications are on", systemImage: "checkmark.circle")
        case .denied:
            Text("Notifications are off. Turn them on in Settings → Brownmellon → Notifications to see safety alerts on the phone.")
                .foregroundStyle(.secondary)
        default:
            Button("Allow notifications") {
                Task {
                    await monitor.requestNotificationPermission()
                    await refreshNotificationStatus(requestIfEnabled: false)
                }
            }
        }
    }

    /// Permission is asked for in Setup only — here, when alerts are (or were
    /// already) enabled — never at launch.
    private func refreshNotificationStatus(requestIfEnabled: Bool) async {
        var status = await monitor.notificationAuthorizationStatus()
        if requestIfEnabled, status == .notDetermined, monitor.settings.isEnabled {
            await monitor.requestNotificationPermission()
            status = await monitor.notificationAuthorizationStatus()
        }
        notificationStatus = status
    }

    // MARK: - Simulator demo

    #if targetEnvironment(simulator)
    private var demoSection: some View {
        Section {
            ForEach(SoundAlertMonitor.DemoSound.allCases) { sound in
                Button {
                    playingDemo = sound
                    Task {
                        await monitor.playDemo(sound)
                        playingDemo = nil
                    }
                } label: {
                    HStack {
                        Text("Play: \(sound.title)")
                        Spacer()
                        if playingDemo == sound { ProgressView() }
                    }
                }
                .disabled(playingDemo != nil || !monitor.isRunning)
            }
            if let last = monitor.lastAnnouncement {
                Text("Last announcement: “\(last)”")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Simulator demo")
        } footer: {
            Text("Plays a clip into the mock glasses' mic tap in real time. Expect the announcement about two seconds in; the smoke alarm is spoken twice and posts a notification.")
        }
    }
    #endif
}
