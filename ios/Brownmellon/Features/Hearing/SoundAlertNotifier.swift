import Foundation
import UIKit
import UserNotifications

/// The redundant channels for Safety alerts (PRD-sound-alerts § 8a): a
/// warning haptic on the phone and a local notification with the sound name
/// and time in large text, for a wearer who may not catch the spoken alert.
@MainActor
protocol SoundAlertNotifying: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    /// Asks the system for notification permission. Only called from Setup,
    /// never at launch.
    func requestAuthorization() async -> Bool
    /// Haptic + "Smoke alarm heard — 8:42 PM".
    func safetyAlert(soundName: String, at date: Date)
}

@MainActor
final class SystemSoundAlertNotifier: NSObject, SoundAlertNotifying {
    private let center = UNUserNotificationCenter.current()
    private let haptics = UINotificationFeedbackGenerator()

    override init() {
        super.init()
        // Without a delegate iOS hides notifications while the app is in the
        // foreground — which is exactly when the Simulator demo runs.
        center.delegate = self
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func safetyAlert(soundName: String, at date: Date) {
        haptics.notificationOccurred(.warning)

        let content = UNMutableNotificationContent()
        content.title = Self.title(soundName: soundName, at: date)
        content.body = "Brownmellon heard this through your glasses. Please check."
        content.sound = .default
        // `.timeSensitive` (breaks through Focus) needs an entitlement this
        // sideloaded build doesn't have; the default level is delivered as-is.

        let request = UNNotificationRequest(
            identifier: "soundAlert.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    /// "Smoke alarm heard — 8:42 PM"
    static func title(soundName: String, at date: Date) -> String {
        "\(soundName) heard — \(date.formatted(date: .omitted, time: .shortened))"
    }
}

extension SystemSoundAlertNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
