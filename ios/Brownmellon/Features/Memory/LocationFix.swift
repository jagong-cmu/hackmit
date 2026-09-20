import Foundation
import CoreLocation
import UIKit

/// A single GPS reading good enough to find a car with.
struct LocationFix: Equatable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double

    init(latitude: Double, longitude: Double, horizontalAccuracy: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
    }

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        horizontalAccuracy = location.horizontalAccuracy
    }

    var clLocation: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

enum LocationFixOutcome: Equatable {
    case fix(LocationFix)
    /// Permission is granted but no acceptable reading arrived in time —
    /// the normal case inside a parking garage.
    case unavailable
    /// The wearer said no (or a restriction says no for them).
    case denied

    var fix: LocationFix? {
        if case let .fix(fix) = self { return fix }
        return nil
    }
}

/// Behind a protocol so the handler's tests never touch Core Location (and
/// never trigger the permission prompt on a test runner).
@MainActor
protocol LocationFixProvider: AnyObject {
    /// Best-effort, bounded: returns within `CoreLocationFixProvider.timeout`
    /// plus however long the wearer takes to answer a first-time permission
    /// prompt. Never throws — a save must never be blocked on GPS.
    func requestFix() async -> LocationFixOutcome
}

/// One-shot `CLLocationUpdate.liveUpdates()` with a timeout and an accuracy
/// gate. Asks for when-in-use permission on first use — that is, the first
/// time the wearer saves a note — not at launch.
@MainActor
final class CoreLocationFixProvider: NSObject, LocationFixProvider {
    static let timeout: Duration = .seconds(5)
    static let maxHorizontalAccuracy: CLLocationAccuracy = 65

    private let manager = CLLocationManager()
    private var authorizationWaiters: [CheckedContinuation<CLAuthorizationStatus, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestFix() async -> LocationFixOutcome {
        var status = manager.authorizationStatus
        if status == .notDetermined {
            // iOS shows the permission alert only while the app is in the
            // foreground. A first save spoken to the glasses with the phone in
            // a pocket would otherwise sit on a prompt nobody can see — and a
            // save must never block on GPS. Skip the fix this once (not
            // "denied": nothing was refused) and ask on the next foreground save.
            guard Self.canPromptForAuthorization() else { return .unavailable }
            status = await requestAuthorization()
        }

        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            return await Self.oneShotFix(timeout: Self.timeout, maxHorizontalAccuracy: Self.maxHorizontalAccuracy)
        case .notDetermined:
            return .unavailable
        default:
            return .denied
        }
    }

    /// Whether the system would actually display the when-in-use alert now.
    /// `.inactive` still counts as foreground (a system alert or the app
    /// switcher is up); only `.background` cannot show it.
    static func canPromptForAuthorization() -> Bool {
        UIApplication.shared.applicationState != .background
    }

    private func requestAuthorization() async -> CLAuthorizationStatus {
        await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    private func authorizationChanged(to status: CLAuthorizationStatus) {
        guard status != .notDetermined else { return }
        let waiters = authorizationWaiters
        authorizationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: status)
        }
    }

    /// Races the live-update stream against the timeout; the first reading
    /// within the accuracy gate wins, otherwise `.unavailable`.
    static func oneShotFix(timeout: Duration, maxHorizontalAccuracy: CLLocationAccuracy) async -> LocationFixOutcome {
        await withTaskGroup(of: LocationFixOutcome.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        guard let location = update.location else { continue }
                        let accuracy = location.horizontalAccuracy
                        if accuracy >= 0, accuracy <= maxHorizontalAccuracy {
                            return .fix(LocationFix(location))
                        }
                    }
                } catch {
                    // Fall through: no fix is a normal outcome, not an error.
                }
                return .unavailable
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .unavailable
            }

            let first = await group.next() ?? .unavailable
            group.cancelAll()
            return first
        }
    }
}

extension CoreLocationFixProvider: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationChanged(to: status) }
    }
}
