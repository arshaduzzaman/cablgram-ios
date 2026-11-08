import Foundation
import MapKit

/// One walking leg between two saved places.
struct WalkLeg {
    let coordinates: [CLLocationCoordinate2D]
    let meters: Double
    let seconds: TimeInterval
    /// True when Apple Maps had no walking route and the leg is a
    /// straight-line estimate.
    let isEstimate: Bool
}

/// A walk that starts and ends at home and visits one or two saved places.
struct WalkSuggestion: Identifiable {
    let stops: [SavedPlace]
    let legs: [WalkLeg]

    var id: String { stops.map(\.id.uuidString).joined(separator: ">") }
    var title: String { stops.map(\.name).joined(separator: " → ") }
    var meters: Double { legs.reduce(0) { $0 + $1.meters } }
    var minutes: Int { Int((legs.reduce(0) { $0 + $1.seconds } / 60).rounded()) }
    var steps: Int { Int(meters * RoutePlanner.stepsPerMeter) }
    var isEstimate: Bool { legs.contains(where: \.isEstimate) }

    /// Map area that shows the whole walk.
    var mapRect: MKMapRect {
        let all = legs.flatMap(\.coordinates)
        let rect = MKPolyline(coordinates: all, count: all.count).boundingMapRect
        let pad = max(rect.width, rect.height) * 0.25 + 300
        return rect.insetBy(dx: -pad, dy: -pad)
    }
}

/// Asks Apple Maps for walking routes between saved places and builds walks
/// out of them.
@MainActor
final class RoutePlanner: ObservableObject {
    /// About 0.76 m per step, an average adult stride.
    nonisolated static let stepsPerMeter = 1.31
    /// Walks longer than this aren't suggested.
    private static let maxWalkMeters = 15_000.0
    /// Caps the number of Apple Maps requests (it throttles at about 50 a minute).
    private static let maxDestinations = 6

    @Published private(set) var suggestions: [WalkSuggestion] = []
    @Published private(set) var isPlanning = false

    private var cache: [String: WalkLeg] = [:]

    func plan(home: SavedPlace?, destinations: [SavedPlace]) async {
        guard let home else {
            suggestions = []
            return
        }
        isPlanning = true
        defer { isPlanning = false }

        let stops = Array(destinations.prefix(Self.maxDestinations))
        var results: [WalkSuggestion] = []

        // Home → place → home.
        for place in stops {
            let legs = [await leg(home, place), await leg(place, home)]
            results.append(WalkSuggestion(stops: [home, place, home], legs: legs))
        }

        // Home → place A → place B → home.
        for i in stops.indices {
            for j in stops.indices where j > i {
                let a = stops[i], b = stops[j]
                let legs = [await leg(home, a), await leg(a, b), await leg(b, home)]
                results.append(WalkSuggestion(stops: [home, a, b, home], legs: legs))
            }
        }

        suggestions = results.filter { $0.meters <= Self.maxWalkMeters }
    }

    private func leg(_ from: SavedPlace, _ to: SavedPlace) async -> WalkLeg {
        let key = "\(from.id)>\(to.id)"
        if let cached = cache[key] { return cached }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.coordinate))
        request.transportType = .walking

        let result: WalkLeg
        if let route = try? await MKDirections(request: request).calculate().routes.first {
            let points = route.polyline.points()
            result = WalkLeg(
                coordinates: (0..<route.polyline.pointCount).map { points[$0].coordinate },
                meters: route.distance,
                seconds: route.expectedTravelTime,
                isEstimate: false
            )
            cache[key] = result
        } else {
            // No walking directions here (or Maps is throttling): estimate
            // from the straight-line distance plus a bit for street layout.
            // Not cached, so a later plan can still get the real route.
            let straight = CLLocation(latitude: from.latitude, longitude: from.longitude)
                .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
            let meters = straight * 1.3
            result = WalkLeg(
                coordinates: [from.coordinate, to.coordinate],
                meters: meters,
                seconds: meters / 1.3,
                isEstimate: true
            )
        }
        return result
    }
}
