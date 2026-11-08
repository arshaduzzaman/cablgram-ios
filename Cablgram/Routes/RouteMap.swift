import SwiftUI
import MapKit
import GoogleMaps

/// The map behind the Routes tab: Google Maps when a key is set, Apple Maps otherwise.
struct RouteMap: View {
    let places: [SavedPlace]
    let walk: WalkSuggestion?
    /// Height covered by the bottom panel, so routes are framed above it.
    var bottomInset: CGFloat = 0
    /// Height covered by floating controls at the top.
    var topInset: CGFloat = 60
    /// False for the small preview on the Walk page: no panning or buttons,
    /// and taps pass through to whatever contains the map.
    var interactive = true

    var body: some View {
        Group {
            if GoogleMapsConfig.isEnabled {
                GoogleRouteMap(places: places, walk: walk, bottomInset: bottomInset,
                               topInset: topInset, interactive: interactive)
            } else {
                AppleRouteMap(places: places, walk: walk, bottomInset: bottomInset,
                              topInset: topInset, interactive: interactive)
            }
        }
        .allowsHitTesting(interactive)
    }
}

/// Round map pin with the place's icon.
struct PlacePin: View {
    let kind: SavedPlace.Kind

    var body: some View {
        Image(systemName: kind.systemImage)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(kind == .home ? AnyShapeStyle(.brandGradient) : AnyShapeStyle(Color.indigo), in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .padding(5)
    }
}

// MARK: - Apple Maps

private struct AppleRouteMap: View {
    let places: [SavedPlace]
    let walk: WalkSuggestion?
    let bottomInset: CGFloat
    let topInset: CGFloat
    let interactive: Bool

    /// `.automatic` frames every pin (and you), so the first view shows all your places.
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()
            ForEach(places) { place in
                Annotation(place.name, coordinate: place.coordinate) {
                    PlacePin(kind: place.kind)
                }
            }
            if let walk {
                ForEach(Array(walk.drawnLegs.enumerated()), id: \.offset) { _, leg in
                    MapPolyline(coordinates: leg.coordinates)
                        .stroke(Color.brand, style: StrokeStyle(lineWidth: 5, lineCap: .round,
                                                                dash: leg.isEstimate ? [8, 8] : []))
                }
            }
        }
        .safeAreaPadding(.bottom, bottomInset)
        .safeAreaPadding(.top, topInset)
        .onChange(of: walk?.id) { _, _ in fit() }
        .onChange(of: places) { _, _ in fit() }
    }

    private func fit() {
        let coordinates = walk?.allCoordinates ?? places.map(\.coordinate)
        guard !coordinates.isEmpty else { return }
        let rect = MKPolyline(coordinates: coordinates, count: coordinates.count).boundingMapRect
        let pad = max(rect.width, rect.height) * 0.15 + 400
        withAnimation { camera = .rect(rect.insetBy(dx: -pad, dy: -pad)) }
    }
}

// MARK: - Google Maps

private struct GoogleRouteMap: UIViewRepresentable {
    let places: [SavedPlace]
    let walk: WalkSuggestion?
    let bottomInset: CGFloat
    let topInset: CGFloat
    let interactive: Bool

    @Environment(\.displayScale) private var displayScale

    final class Coordinator {
        var lastFitKey: String?
        var pinImages: [SavedPlace.Kind: UIImage] = [:]
        var didCenterOnUser = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> GMSMapView {
        let options = GMSMapViewOptions()
        // Dhaka, until we know where the user or their places are.
        options.camera = GMSCameraPosition(latitude: 23.75, longitude: 90.39, zoom: 13)
        let map = GMSMapView(options: options)
        map.isMyLocationEnabled = true
        map.settings.myLocationButton = interactive
        map.settings.compassButton = interactive
        map.settings.setAllGesturesEnabled(interactive)
        return map
    }

    func updateUIView(_ map: GMSMapView, context: Context) {
        map.padding = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        map.clear()

        for place in places {
            let marker = GMSMarker(position: place.coordinate)
            marker.title = place.name
            marker.icon = pinImage(for: place.kind, context: context)
            marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
            marker.map = map
        }

        if let walk {
            for leg in walk.drawnLegs {
                let path = GMSMutablePath()
                leg.coordinates.forEach { path.add($0) }
                let line = GMSPolyline(path: path)
                line.strokeWidth = 5
                line.strokeColor = UIColor(Color.brand)
                if leg.isEstimate {
                    line.spans = GMSStyleSpans(path,
                                               [GMSStrokeStyle.solidColor(UIColor(Color.brand)), GMSStrokeStyle.solidColor(.clear)],
                                               [40, 30], .rhumb)
                }
                line.map = map
            }
        }

        // Re-frame only when the selected walk or the set of places changes.
        let fitKey = walk?.id ?? places.map(\.id.uuidString).joined()
        guard fitKey != context.coordinator.lastFitKey else { return }
        context.coordinator.lastFitKey = fitKey

        let coordinates = walk?.allCoordinates ?? places.map(\.coordinate)
        if coordinates.count == 1, let only = coordinates.first {
            map.animate(to: GMSCameraPosition(target: only, zoom: 15))
        } else if coordinates.count > 1 {
            let path = GMSMutablePath()
            coordinates.forEach { path.add($0) }
            map.animate(with: GMSCameraUpdate.fit(GMSCoordinateBounds(path: path), withPadding: 50))
        }
    }

    @MainActor
    private func pinImage(for kind: SavedPlace.Kind, context: Context) -> UIImage? {
        if let cached = context.coordinator.pinImages[kind] { return cached }
        let renderer = ImageRenderer(content: PlacePin(kind: kind).environment(\.colorScheme, .light))
        renderer.scale = displayScale
        let image = renderer.uiImage
        context.coordinator.pinImages[kind] = image
        return image
    }
}
