import Foundation

/// What the caregiver chose in Setup → Sound Alerts. Persisted through
/// `SecureLocalStore` under `SoundAlertSettings.storageKey`, same pattern as
/// `EmergencyContactSetupViewModel`.
///
/// The threshold and the two-window rule are settings rather than constants
/// on purpose: HFP mic audio is band-limited and will lower the classifier's
/// confidence on hardware (PRD § Audio path), so they may need tuning.
struct SoundAlertSettings: Codable, Equatable, Sendable {
    static let storageKey = "soundAlertSettings"

    /// Master switch. Detection is always-on from launch while this is true.
    var isEnabled: Bool = true

    /// Which rows of the table are announced. Everything but Ambient by default.
    var enabledGroups: Set<SoundGroup> = Set(SoundGroup.allCases.filter(\.isOnByDefault))

    /// Minimum classifier confidence for a window to count.
    var confidenceThreshold: Double = 0.7

    /// How many consecutive windows must clear the threshold before we speak.
    var requiredConsecutiveWindows: Int = 2

    static let `default` = SoundAlertSettings()

    /// True only when both the master switch and the group are on.
    func isEnabled(_ group: SoundGroup) -> Bool {
        isEnabled && enabledGroups.contains(group)
    }

    mutating func setGroup(_ group: SoundGroup, enabled: Bool) {
        if enabled {
            enabledGroups.insert(group)
        } else {
            enabledGroups.remove(group)
        }
    }
}
