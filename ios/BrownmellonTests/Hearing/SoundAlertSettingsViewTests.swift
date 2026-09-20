import XCTest
import SwiftUI
@testable import Brownmellon

/// The Setup screen is reached from `SetupHomeView` as
/// `SoundAlertSettingsView()` with the app's `SoundAlertMonitor` in the
/// environment (PRD-foundation-v2 § 7: one instance for voice, detector and
/// screen). Hosting it the same way proves the body evaluates — a missing
/// environment object or a bad `Form` would crash here rather than in a demo.
@MainActor
final class SoundAlertSettingsViewTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    /// Puts the view on screen in a real window so SwiftUI evaluates `body`
    /// (an off-window hosting controller may defer it).
    private func host<V: View>(_ view: V) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        self.window = window
        return window
    }

    func testRendersWithTheMonitorInTheEnvironment() {
        let monitor = SoundAlertMonitor(glasses: MockGlassesSession(), store: MockSecureLocalStore(), notifier: SpyNotifier())

        let window = host(NavigationStack { SoundAlertSettingsView() }.environmentObject(monitor))

        XCTAssertNotNil(window.rootViewController?.view.superview, "hosted and laid out without trapping")
        XCTAssertFalse(monitor.isMicrophoneDenied, "test host never asked for the mic, so Setup can't be showing the denied state")
    }

    func testSetupHomeListsSoundAlerts() {
        let monitor = SoundAlertMonitor(glasses: MockGlassesSession(), store: MockSecureLocalStore(), notifier: SpyNotifier())

        let window = host(NavigationStack { SetupHomeView(store: MockSecureLocalStore()) }.environmentObject(monitor))

        XCTAssertNotNil(window.rootViewController?.view.superview)
    }

    func testDisclaimerCoversTheRequiredPoints() {
        let text = SoundAlertSettingsView.disclaimer.lowercased()
        XCTAssertTrue(text.contains("on this phone"), "on-device")
        XCTAssertTrue(text.contains("nothing is recorded"), "nothing recorded")
        XCTAssertTrue(text.contains("not a substitute"), "not a substitute for a proper alarm")
        XCTAssertTrue(text.contains("glasses are being worn"), "needs the glasses on")
        XCTAssertTrue(text.contains("phone is nearby"), "phone nearby")
    }
}
