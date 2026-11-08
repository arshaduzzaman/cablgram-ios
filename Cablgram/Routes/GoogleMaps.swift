import Foundation
import CoreLocation
import GoogleMaps

/// Reads the Google Maps API key from Info.plist (set via App.xcconfig /
/// Secrets.xcconfig). With no key, the app uses Apple Maps instead.
enum GoogleMapsConfig {
    static let apiKey: String = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "GoogleMapsAPIKey") as? String ?? ""
        return raw.trimmingCharacters(in: .whitespaces)
    }()

    static var isEnabled: Bool {
        !apiKey.isEmpty && !apiKey.hasPrefix("$(") && apiKey != "paste-your-key-here"
    }

    static func activate() {
        if isEnabled { GMSServices.provideAPIKey(apiKey) }
    }
}

/// Error body Google returns on a failed request.
private struct GoogleFailure: Decodable {
    struct Inner: Decodable { let message: String }
    let error: Inner
}

/// One turn-by-turn instruction.
struct NavStep {
    let instruction: String
    /// Google maneuver, e.g. TURN_LEFT, STRAIGHT, ROUNDABOUT_RIGHT.
    let maneuver: String
    let meters: Double
    let end: CLLocationCoordinate2D
}

/// A walking route for navigation: the line to draw and the turns along it.
struct NavRoute {
    let coordinates: [CLLocationCoordinate2D]
    let steps: [NavStep]
    let meters: Double
    let seconds: Double
}

struct GoogleAPIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Google's web APIs, called with the same key. Requests send the app's
/// bundle id so a key restricted to this iOS app still works.
enum GoogleAPI {
    private static func post<Response: Decodable>(_ url: String, fieldMask: String, body: [String: Any]) async throws -> Response {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(GoogleMapsConfig.apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(fieldMask, forHTTPHeaderField: "X-Goog-FieldMask")
        if let bundleID = Bundle.main.bundleIdentifier {
            request.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(GoogleFailure.self, from: data))?.error.message
            throw GoogleAPIError(message: message ?? "Google request failed.")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private static func waypoint(_ c: CLLocationCoordinate2D) -> [String: Any] {
        ["location": ["latLng": ["latitude": c.latitude, "longitude": c.longitude]]]
    }

    // MARK: Routes API

    /// One walking route through all `points` in order (first = start, last = end).
    static func walkingRoute(through points: [CLLocationCoordinate2D]) async throws -> WalkLeg {
        guard let first = points.first, let last = points.last, points.count >= 2 else {
            throw GoogleAPIError(message: "A route needs at least two points.")
        }
        var body: [String: Any] = [
            "origin": waypoint(first),
            "destination": waypoint(last),
            "travelMode": "WALK",
        ]
        if points.count > 2 {
            body["intermediates"] = points.dropFirst().dropLast().map(waypoint)
        }

        struct Result: Decodable {
            struct Route: Decodable {
                struct Polyline: Decodable { let encodedPolyline: String }
                let distanceMeters: Double?
                let duration: String?
                let polyline: Polyline?
            }
            let routes: [Route]?
        }
        let result: Result = try await post(
            "https://routes.googleapis.com/directions/v2:computeRoutes",
            fieldMask: "routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline",
            body: body
        )
        guard let route = result.routes?.first, let meters = route.distanceMeters else {
            throw GoogleAPIError(message: "Google found no walking route.")
        }
        let seconds = Double(route.duration?.replacingOccurrences(of: "s", with: "") ?? "") ?? meters / 1.3
        let coordinates = route.polyline.map { decodePolyline($0.encodedPolyline) } ?? points
        return WalkLeg(coordinates: coordinates, meters: meters, seconds: seconds, isEstimate: false)
    }

    /// Walking route with turn-by-turn steps through `points` in order.
    static func walkingNavigation(through points: [CLLocationCoordinate2D]) async throws -> NavRoute {
        guard let first = points.first, let last = points.last, points.count >= 2 else {
            throw GoogleAPIError(message: "A route needs at least two points.")
        }
        var body: [String: Any] = [
            "origin": waypoint(first),
            "destination": waypoint(last),
            "travelMode": "WALK",
        ]
        if points.count > 2 {
            body["intermediates"] = points.dropFirst().dropLast().map(waypoint)
        }

        struct Result: Decodable {
            struct LatLng: Decodable { let latitude: Double; let longitude: Double }
            struct Location: Decodable { let latLng: LatLng }
            struct Instruction: Decodable { let maneuver: String?; let instructions: String? }
            struct Step: Decodable {
                let distanceMeters: Double?
                let endLocation: Location?
                let navigationInstruction: Instruction?
            }
            struct Leg: Decodable { let steps: [Step]? }
            struct Polyline: Decodable { let encodedPolyline: String }
            struct Route: Decodable {
                let distanceMeters: Double?
                let duration: String?
                let polyline: Polyline?
                let legs: [Leg]?
            }
            let routes: [Route]?
        }
        let result: Result = try await post(
            "https://routes.googleapis.com/directions/v2:computeRoutes",
            fieldMask: "routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline,routes.legs.steps.distanceMeters,routes.legs.steps.endLocation,routes.legs.steps.navigationInstruction",
            body: body
        )
        guard let route = result.routes?.first, let meters = route.distanceMeters else {
            throw GoogleAPIError(message: "Google found no walking route.")
        }
        let steps: [NavStep] = (route.legs ?? []).flatMap { $0.steps ?? [] }.compactMap { step in
            guard let end = step.endLocation?.latLng else { return nil }
            return NavStep(instruction: step.navigationInstruction?.instructions ?? "Continue",
                           maneuver: step.navigationInstruction?.maneuver ?? "STRAIGHT",
                           meters: step.distanceMeters ?? 0,
                           end: CLLocationCoordinate2D(latitude: end.latitude, longitude: end.longitude))
        }
        let seconds = Double(route.duration?.replacingOccurrences(of: "s", with: "") ?? "") ?? meters / 1.3
        return NavRoute(coordinates: route.polyline.map { decodePolyline($0.encodedPolyline) } ?? points,
                        steps: steps, meters: meters, seconds: seconds)
    }

    // MARK: Places API (New)

    static func searchPlaces(_ text: String, near: CLLocation?) async throws -> [PlaceResult] {
        var body: [String: Any] = ["textQuery": text]
        if let near {
            body["locationBias"] = ["circle": [
                "center": ["latitude": near.coordinate.latitude, "longitude": near.coordinate.longitude],
                "radius": 30_000.0,
            ]]
        }

        struct Result: Decodable {
            struct Place: Decodable {
                struct Name: Decodable { let text: String }
                struct Location: Decodable { let latitude: Double; let longitude: Double }
                let displayName: Name?
                let formattedAddress: String?
                let location: Location?
            }
            let places: [Place]?
        }
        let result: Result = try await post(
            "https://places.googleapis.com/v1/places:searchText",
            fieldMask: "places.displayName,places.formattedAddress,places.location",
            body: body
        )
        return (result.places ?? []).compactMap { place in
            guard let location = place.location else { return nil }
            return PlaceResult(name: place.displayName?.text ?? "Place",
                               address: place.formattedAddress,
                               latitude: location.latitude,
                               longitude: location.longitude)
        }
    }

    /// Decodes Google's encoded polyline format.
    static func decodePolyline(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        let bytes = Array(encoded.utf8)
        var index = 0, lat = 0, lng = 0

        func nextValue() -> Int? {
            var result = 0, shift = 0
            while index < bytes.count {
                let byte = Int(bytes[index]) - 63
                index += 1
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20 {
                    return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
                }
            }
            return nil
        }

        while index < bytes.count {
            guard let dLat = nextValue(), let dLng = nextValue() else { break }
            lat += dLat
            lng += dLng
            coordinates.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e5, longitude: Double(lng) / 1e5))
        }
        return coordinates
    }
}
