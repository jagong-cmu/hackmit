import Foundation
import UIKit

/// Places the actual call for Feature 6. Native iOS `tel:` — no dependency
/// on anyone else's shared foundation piece (PRD § Workstream C).
///
/// PRD requirement: iOS does not let a third-party app complete a call,
/// including to 911, without the wearer (or a bystander) confirming with a
/// tap on the phone's own call screen. `open(_:)` gets the wearer to that
/// screen; it cannot and must not claim to finish the call itself — the
/// glasses' spoken confirmation should say so explicitly (see PRD § Feature 6).
///
/// Not yet implemented: the PRD calls for a single dedicated trigger
/// phrase with "its own always-on listener, bypassing the general NLU
/// pipeline entirely." That's a separate, always-listening speech
/// recognizer independent of `WakeWordListener` — real device/DAT work,
/// not something to fake convincingly on Simulator. This scaffold exposes
/// the call-placement half only; wire a dedicated listener to
/// `EmergencyContactSetupViewModel.callNow(_:)` once that infrastructure exists.
enum EmergencyCallService {
    static let emergencyNumber = "911"

    @discardableResult
    static func call(_ phoneNumber: String) -> Bool {
        let digits = phoneNumber.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "tel://\(digits)"), UIApplication.shared.canOpenURL(url) else {
            return false
        }
        UIApplication.shared.open(url)
        return true
    }
}
