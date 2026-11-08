import Foundation
import CoreLocation
import CoreMotion

/// A walk in progress: follows your location, counts steps live with the
/// motion chip, and works out the next turn along the route.
@MainActor
final class WalkSession: NSObject, ObservableObject, CLLocationManagerDelegate {
    let walk: WalkSuggestion?
    let startDate = Date()

    @Published private(set) var location: CLLocation?
    @Published private(set) var heading: CLLocationDirection = 0
    @Published private(set) var walkedSteps = 0
    @Published private(set) var walkedMeters: Double = 0
    @Published private(set) var route: NavRoute?
    @Published private(set) var stepIndex = 0
    @Published private(set) var isLoadingRoute = false
    @Published private(set) var arrived = false

    private let manager = CLLocationManager()
    private let pedometer = CMPedometer()
    /// How close you must get to a turn before moving to the next one.
    private let arrivalRadius: CLLocationDistance = 20

    init(walk: WalkSuggestion?) {
        self.walk = walk
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

        guard let walk else { return }
        isLoadingRoute = true
        if GoogleMapsConfig.isEnabled,
           let nav = try? await GoogleAPI.walkingNavigation(through: walk.stops.map(\.coordinate)) {
            route = nav
        } else {
            route = NavRoute(coordinates: walk.allCoordinates, steps: [], meters: walk.meters,
                             seconds: Double(walk.minutes * 60))
        }
        isLoadingRoute = false
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        pedometer.stopUpdates()
    }

    // MARK: - Route progress

    var currentStep: NavStep? {
        guard let steps = route?.steps, stepIndex < steps.count else { return nil }
        return steps[stepIndex]
    }

    var metersToTurn: Double? {
        guard let location, let step = currentStep else { return nil }
        return location.distance(from: CLLocation(latitude: step.end.latitude, longitude: step.end.longitude))
    }

    /// Distance left on the route.
    var remainingMeters: Double? {
        guard let route else { return nil }
        if route.steps.isEmpty { return max(route.meters - walkedMeters, 0) }
        let later = route.steps.dropFirst(stepIndex + 1).reduce(0) { $0 + $1.meters }
        return (metersToTurn ?? currentStep?.meters ?? 0) + later
    }

    /// True when the step after this one is the last.
    var isFinalStep: Bool {
        guard let steps = route?.steps else { return false }
        return stepIndex >= steps.count - 1
    }

    private func advanceIfNeeded() {
        guard let steps = route?.steps, !steps.isEmpty, !arrived else { return }
        while let distance = metersToTurn, distance < arrivalRadius {
            if stepIndex >= steps.count - 1 {
                arrived = true
                return
            }
            stepIndex += 1
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in
            self.location = latest
            if latest.course >= 0, latest.speed > 0.5 { self.heading = latest.course }
            self.advanceIfNeeded()
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
