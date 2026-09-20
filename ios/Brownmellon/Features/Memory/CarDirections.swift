import Foundation
import CoreLocation
import MapKit

/// "Take me to my car": hands the saved coordinate to Apple Maps for
/// walking directions. Behind a protocol so tests can assert the request
/// without launching Maps.
@MainActor
protocol DirectionsOpener: AnyObject {
    func openWalkingDirections(to coordinate: CLLocationCoordinate2D)
}

@MainActor
final class MapsDirectionsOpener: DirectionsOpener {
    func openWalkingDirections(to coordinate: CLLocationCoordinate2D) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = "My car"
        _ = item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking,
        ])
    }
}
