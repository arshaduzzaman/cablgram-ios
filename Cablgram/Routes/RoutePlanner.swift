import Foundation
import MapKit

/// One stretch of walking, drawn as a line on the map.
struct WalkLeg {
    let coordinates: [CLLocationCoordinate2D]
    let meters: Double
    let seconds: TimeInterval
    /// True when no map service had a walking route and this is a
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
    var allCoordinates: [CLLocationCoordinate2D] { legs.flatMap(\.coordinates) }

    /// Legs to draw. A straight-line estimate there and back would draw the
    /// same line twice and hide the dashes, so each estimated line is drawn once.
    var drawnLegs: [WalkLeg] {
        var seen = Set<String>()
        return legs.filter { leg in
            guard leg.isEstimate, let a = leg.coordinates.first, let b = leg.coordinates.last else { return true }
            let ends = [a, b].map { "\($0.latitude),\($0.longitude)" }.sorted().joined(separator: "|")
            return seen.insert(ends).inserted
        }
    }
}

/// Builds walks between saved places. Uses Google's Routes API when a key is
/// set, otherwise Apple Maps, and falls back to straight-line estimates.
@MainActor
final class RoutePlanner: ObservableObject {
    /// About 0.76 m per step, an average adult stride.
    nonisolated static let stepsPerMeter = 1.31
    /// Walks longer than this aren't suggested.
    private static let maxWalkMeters = 15_000.0
    /// Limits how many map requests one plan makes.
    private static let maxDestinations = 6

    @Published private(set) var suggestions: [WalkSuggestion] = []
    @Published private(set) var isPlanning = false
    /// Last Google error, shown so a bad key or disabled API is easy to spot.
    @Published private(set) var googleError: String?

    private var googleCache: [String: WalkLeg] = [:]
    private var appleCache: [String: WalkLeg] = [:]

    func plan(home: SavedPlace?, destinations: [SavedPlace]) async {
        guard let home else {
            suggestions = []
            return
        }
        isPlanning = true
        defer { isPlanning = false }
        googleError = nil

        let places = Array(destinations.prefix(Self.maxDestinations))
        var routes: [[SavedPlace]] = places.map { [home, $0, home] }
        for i in places.indices {
            for j in places.indices where j > i {
                routes.append([home, places[i], places[j], home])
            }
        }

        var results: [WalkSuggestion] = []
        for stops in routes {
            results.append(await suggestion(for: stops))
        }
        suggestions = results.filter { $0.meters <= Self.maxWalkMeters }
    }

    private func suggestion(for stops: [SavedPlace]) async -> WalkSuggestion {
        if GoogleMapsConfig.isEnabled {
            let key = stops.map(\.id.uuidString).joined(separator: ">")
            if let cached = googleCache[key] {
                return WalkSuggestion(stops: stops, legs: [cached])
            }
            do {
                let leg = try await GoogleAPI.walkingRoute(through: stops.map(\.coordinate))
                googleCache[key] = leg
                return WalkSuggestion(stops: stops, legs: [leg])
            } catch {
                googleError = error.localizedDescription
            }
        }

        var legs: [WalkLeg] = []
        for (from, to) in zip(stops, stops.dropFirst()) {
            legs.append(await appleLeg(from, to))
        }
        return WalkSuggestion(stops: stops, legs: legs)
    }

    private func appleLeg(_ from: SavedPlace, _ to: SavedPlace) async -> WalkLeg {
        let key = "\(from.id)>\(to.id)"
        if let cached = appleCache[key] { return cached }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.coordinate))
        request.transportType = .walking

        if let route = try? await MKDirections(request: request).calculate().routes.first {
            let points = route.polyline.points()
            let leg = WalkLeg(
                coordinates: (0..<route.polyline.pointCount).map { points[$0].coordinate },
                meters: route.distance,
                seconds: route.expectedTravelTime,
                isEstimate: false
            )
            appleCache[key] = leg
            return leg
        }

        // No walking directions here: estimate from the straight-line
        // distance plus a bit for the street layout. Not cached, so a later
        // plan can still get the real route.
        let straight = CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
        let meters = straight * 1.3
        return WalkLeg(coordinates: [from.coordinate, to.coordinate],
                       meters: meters, seconds: meters / 1.3, isEstimate: true)
    }
}

/// A search result for the Add Place screen.
struct PlaceResult: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let address: String?
    let latitude: Double
    let longitude: Double
}

enum PlaceSearch {
    /// Searches Google Places when a key is set, otherwise (or if Google
    /// fails) Apple Maps.
    static func search(_ text: String, near: CLLocation?) async -> [PlaceResult] {
        if GoogleMapsConfig.isEnabled,
           let results = try? await GoogleAPI.searchPlaces(text, near: near), !results.isEmpty {
            return results
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let near {
            request.region = MKCoordinateRegion(center: near.coordinate,
                                                latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        }
        let items = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
        return items.map {
            PlaceResult(name: $0.name ?? "Place", address: $0.placemark.title,
                        latitude: $0.placemark.coordinate.latitude,
                        longitude: $0.placemark.coordinate.longitude)
        }
    }
}
