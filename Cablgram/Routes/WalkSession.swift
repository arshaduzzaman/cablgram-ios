import Foundation
import CoreLocation
import CoreMotion

/// A walk in progress: follows your location and counts steps live with
/// the motion chip.
@MainActor
final class WalkSession: NSObject, ObservableObject, CLLocationManagerDelegate {
    let startDate = Date()

    @Published private(set) var location: CLLocation?
    @Published private(set) var heading: CLLocationDirection = 0
    @Published private(set) var walkedSteps = 0
    @Published private(set) var walkedMeters: Double = 0

    private let manager = CLLocationManager()
    private let pedometer = CMPedometer()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 4
        manager.activityType = .fitness
    }

    func start() async {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()

        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: startDate) { [weak self] data, _ in
                guard let data else { return }
                let steps = data.numberOfSteps.intValue
                let meters = data.distance?.doubleValue
                Task { @MainActor in
                    self?.walkedSteps = steps
                    if let meters { self?.walkedMeters = meters }
                }
            }
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        pedometer.stopUpdates()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in
            self.location = latest
            if latest.course >= 0, latest.speed > 0.5 { self.heading = latest.course }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in
            // Prefer the compass when standing still; GPS course takes over while moving.
            if (self.location?.speed ?? 0) <= 0.5 { self.heading = value }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
