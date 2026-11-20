import Foundation
import CoreLocation
import FirebaseAuth
import FirebaseFirestore

/// Location for the admin dashboard, only while the app is open ("when in use"):
/// - your approximate area (city and country, position rounded to about 1 km) in
///   `users/{uid}.location`, refreshed at most every few hours;
/// - the route you walk while the Walk tab is on screen, saved to `users/{uid}/routes`.
/// Android writes the same fields.
@MainActor
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationTracker()

    private let manager = CLLocationManager()
    private var wantsArea = false
    private var recording = false
    /// The Walk tab is showing: start recording as soon as location is allowed.
    private var wantsRecording = false
    private var routeStart: Date?
    private var points: [CLLocation] = []

    /// Routes shorter than this aren't saved (standing still, GPS drift).
    private static let minRouteMeters: CLLocationDistance = 50
    /// Faster than this is a car or bus, not a walk: those points are skipped.
    private static let maxWalkingSpeed: CLLocationSpeed = 4.5
    private static let maxPoints = 1500
    private static let areaKey = "location.areaUpdatedAt"
    private static let areaInterval: TimeInterval = 3 * 60 * 60

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 8
        manager.activityType = .fitness
    }

    private var isAllowed: Bool {
        [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus)
    }

    /// Shows the system prompt the first time; does nothing after that.
    func requestPermission() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// Saves your approximate area, unless it was saved recently.
    func refreshArea(force: Bool = false) {
        guard AuthStore.isConfigured, Auth.auth().currentUser != nil, isAllowed else { return }
        let last = UserDefaults.standard.double(forKey: Self.areaKey)
        if !force, last > 0, Date().timeIntervalSince1970 - last < Self.areaInterval { return }
        wantsArea = true
        if !recording { manager.requestLocation() }
    }

    /// Starts or stops recording a route (Walk tab on screen and the app open).
    func setRecording(_ on: Bool) {
        wantsRecording = on
        if on {
            guard !recording, isAllowed, AuthStore.isConfigured, Auth.auth().currentUser != nil else { return }
            recording = true
            routeStart = Date()
            points = []
            manager.startUpdatingLocation()
        } else {
            guard recording else { return }
            recording = false
            manager.stopUpdatingLocation()
            saveRoute()
        }
    }

    // MARK: - Saving

    private func saveRoute() {
        defer { points = []; routeStart = nil }
        guard let start = routeStart, points.count >= 2, let user = Auth.auth().currentUser else { return }
        var meters: CLLocationDistance = 0
        for (a, b) in zip(points, points.dropFirst()) { meters += b.distance(from: a) }
        guard meters >= Self.minRouteMeters else { return }

        let data: [String: Any] = [
            "startedAt": Timestamp(date: start),
            "endedAt": Timestamp(date: points.last?.timestamp ?? Date()),
            "distance": Int(meters.rounded()),
            "points": points.map { ["lat": round6($0.coordinate.latitude),
                                    "lng": round6($0.coordinate.longitude),
                                    "t": Timestamp(date: $0.timestamp)] },
            "platform": "ios",
            "savedAt": FieldValue.serverTimestamp(),
        ]
        Firestore.firestore().collection("users").document(user.uid).collection("routes").addDocument(data: data)
    }

    private func saveArea(from location: CLLocation) {
        guard let user = Auth.auth().currentUser else { return }
        wantsArea = false
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.areaKey)
        CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
            let place = placemarks?.first
            var area: [String: Any] = [
                // About 1 km: enough for a map of where users are, not their address.
                "lat": (location.coordinate.latitude * 100).rounded() / 100,
                "lng": (location.coordinate.longitude * 100).rounded() / 100,
                "at": FieldValue.serverTimestamp(),
            ]
            if let city = place?.locality ?? place?.subAdministrativeArea { area["city"] = city }
            if let region = place?.administrativeArea { area["region"] = region }
            if let country = place?.country { area["country"] = country }
            if let code = place?.isoCountryCode { area["countryCode"] = code }
            Firestore.firestore().collection("users").document(user.uid)
                // lastSeen and platform go along so the write passes the profile rules.
                .setData(["location": area, "platform": "ios", "lastSeen": FieldValue.serverTimestamp()], merge: true)
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            // Just allowed: save the area now, and start the route if you're on the Walk tab.
            guard self.isAllowed else { return }
            self.refreshArea()
            if self.wantsRecording { self.setRecording(true) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for location in locations where location.horizontalAccuracy >= 0 {
                if self.wantsArea, location.horizontalAccuracy <= 3000 { self.saveArea(from: location) }
                guard self.recording, location.horizontalAccuracy <= 40,
                      location.speed < Self.maxWalkingSpeed,
                      self.points.count < Self.maxPoints else { continue }
                if let last = self.points.last, location.distance(from: last) < 8 { continue }
                self.points.append(location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

private func round6(_ value: Double) -> Double { (value * 1_000_000).rounded() / 1_000_000 }
