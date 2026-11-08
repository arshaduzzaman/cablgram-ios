import Foundation
import CoreLocation

/// A place the user goes often. Saved on the phone only — home and work
/// addresses never leave the device.
struct SavedPlace: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case home, work, school, mosque, market, gym, park, friend, other

        var id: String { rawValue }

        var label: String {
            switch self {
            case .friend: "Friend's place"
            default: rawValue.capitalized
            }
        }

        var systemImage: String {
            switch self {
            case .home: "house.fill"
            case .work: "briefcase.fill"
            case .school: "graduationcap.fill"
            case .mosque: "moon.stars.fill"
            case .market: "cart.fill"
            case .gym: "dumbbell.fill"
            case .park: "tree.fill"
            case .friend: "person.2.fill"
            case .other: "mappin"
            }
        }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

@MainActor
final class PlacesStore: ObservableObject {
    @Published private(set) var places: [SavedPlace] = []

    private let key = "routes.places"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([SavedPlace].self, from: data) {
            places = saved
        }
    }

    var home: SavedPlace? { places.first { $0.kind == .home } }
    var destinations: [SavedPlace] { places.filter { $0.kind != .home } }

    /// Adds a place. There is only one home, so a new home replaces the old one.
    func add(_ place: SavedPlace) {
        if place.kind == .home {
            places.removeAll { $0.kind == .home }
        }
        places.append(place)
        save()
    }

    func remove(_ place: SavedPlace) {
        places.removeAll { $0.id == place.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    #if DEBUG
    /// A home in Dhanmondi plus a few common Dhaka stops, for testing.
    func addSampleDhakaPlaces() {
        let samples: [SavedPlace] = [
            SavedPlace(name: "Home", kind: .home, latitude: 23.7465, longitude: 90.3760),
            SavedPlace(name: "New Market", kind: .market, latitude: 23.7333, longitude: 90.3847),
            SavedPlace(name: "Dhaka University", kind: .school, latitude: 23.7340, longitude: 90.3925),
            SavedPlace(name: "Baitul Mukarram", kind: .mosque, latitude: 23.7290, longitude: 90.4126),
            SavedPlace(name: "Ramna Park", kind: .park, latitude: 23.7383, longitude: 90.4020),
        ]
        places = samples
        save()
    }
    #endif
}
