import Foundation
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

    /// Black-and-white map, so Cablgram's pink route and pins are the only colour.
    static let monochromeStyle = """
    [{"stylers":[{"saturation":-100}]},
     {"featureType":"water","stylers":[{"lightness":-8}]},
     {"featureType":"poi.business","stylers":[{"visibility":"off"}]},
     {"featureType":"transit","elementType":"labels.icon","stylers":[{"visibility":"off"}]}]
    """

    static func activate() {
        if isEnabled { GMSServices.provideAPIKey(apiKey) }
    }
}
