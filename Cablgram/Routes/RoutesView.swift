import SwiftUI
import MapKit

/// Map of your usual places, plus walks between them that reach today's
/// step goal.
struct RoutesView: View {
    @EnvironmentObject private var steps: StepStore
    @StateObject private var places = PlacesStore()
    @StateObject private var planner = RoutePlanner()
    @StateObject private var location = LocationTracker()

    @AppStorage("walk.dailyGoal") private var dailyGoal = 8_000
    @State private var selectedID: WalkSuggestion.ID?
    @State private var addingKind: SavedPlace.Kind?
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    private var stepsNeeded: Int { max(dailyGoal - steps.stepsToday, 0) }

    /// Walks that reach the goal first (shortest first), then the rest
    /// (longest first, since they get closest).
    private var ranked: [WalkSuggestion] {
        let all = planner.suggestions
        let reaching = all.filter { $0.steps >= stepsNeeded }.sorted { $0.steps < $1.steps }
        let short = all.filter { $0.steps < stepsNeeded }.sorted { $0.steps > $1.steps }
        return Array((reaching + short).prefix(8))
    }

    private var selected: WalkSuggestion? {
        planner.suggestions.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                map
                    .frame(height: 280)
                List {
                    goalSection
                    suggestionsSection
                    placesSection
                }
            }
            .navigationTitle("Routes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button { addingKind = places.home == nil ? .home : .other } label: {
                    Image(systemName: "plus")
                }
            }
            .sheet(item: $addingKind) { kind in
                AddPlaceView(initialKind: kind, currentLocation: location.lastLocation) { place in
                    places.add(place)
                }
            }
            .task(id: places.places) {
                selectedID = nil
                camera = .automatic
                await planner.plan(home: places.home, destinations: places.destinations)
            }
            .onAppear { location.requestOnce() }
            .onChange(of: selectedID) { _, _ in
                withAnimation {
                    camera = selected.map { .rect($0.mapRect) } ?? .automatic
                }
            }
        }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()

            ForEach(places.places) { place in
                Annotation(place.name, coordinate: place.coordinate) {
                    Image(systemName: place.kind.systemImage)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(place.kind == .home ? Color.brand : Color.indigo, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }

            if let selected {
                ForEach(Array(drawnLegs(of: selected).enumerated()), id: \.offset) { _, leg in
                    MapPolyline(coordinates: leg.coordinates)
                        .stroke(Color.brand, style: StrokeStyle(lineWidth: 5, lineCap: .round,
                                                                dash: leg.isEstimate ? [8, 8] : []))
                }
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
    }

    /// Legs to draw. A straight-line estimate there and back would draw the
    /// same line twice and hide the dashes, so each estimated line is drawn once.
    private func drawnLegs(of walk: WalkSuggestion) -> [WalkLeg] {
        var seen = Set<String>()
        return walk.legs.filter { leg in
            guard leg.isEstimate, let a = leg.coordinates.first, let b = leg.coordinates.last else { return true }
            let ends = [a, b].map { "\($0.latitude),\($0.longitude)" }.sorted().joined(separator: "|")
            return seen.insert(ends).inserted
        }
    }

    // MARK: - Sections

    private var goalSection: some View {
        Section {
            Stepper(value: $dailyGoal, in: 2_000...30_000, step: 1_000) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily goal: \(dailyGoal.formatted()) steps").font(.headline)
                    Text(stepsNeeded == 0
                         ? "Goal reached today 🎉"
                         : "\(stepsNeeded.formatted()) more steps to go today")
                        .font(.subheadline)
                        .foregroundStyle(stepsNeeded == 0 ? Color.brand : .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        Section {
            if places.home == nil {
                Button { addingKind = .home } label: {
                    Label("Set your home to get walk ideas", systemImage: "house.fill")
                }
            } else if places.destinations.isEmpty {
                Button { addingKind = .other } label: {
                    Label("Add places you go often", systemImage: "mappin.and.ellipse")
                }
            } else if planner.isPlanning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finding walking routes…").foregroundStyle(.secondary)
                }
            } else {
                ForEach(ranked) { walk in
                    SuggestionRow(walk: walk,
                                  reachesGoal: stepsNeeded > 0 && walk.steps >= stepsNeeded,
                                  isSelected: walk.id == selectedID)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedID = selectedID == walk.id ? nil : walk.id
                        }
                }
            }

            if stepsNeeded > 0 {
                Label {
                    Text("Taking a rickshaw or bus today? Get off 1 km early and walk the rest: about **+1,300 steps**.")
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                }
            }
        } header: {
            Text("Ways to reach your goal")
        } footer: {
            if planner.suggestions.contains(where: \.isEstimate) {
                Text("Dashed lines are estimates where Apple Maps has no walking route.")
            }
        }
    }

    private var placesSection: some View {
        Section {
            ForEach(places.places) { place in
                Label(place.name, systemImage: place.kind.systemImage)
            }
            .onDelete { offsets in
                offsets.map { places.places[$0] }.forEach(places.remove)
            }
            Button { addingKind = places.home == nil ? .home : .other } label: {
                Label("Add a place", systemImage: "plus.circle.fill")
            }
            #if DEBUG
            Button("Load sample Dhaka places (debug)") { places.addSampleDhakaPlaces() }
            #endif
        } header: {
            Text("Your places")
        } footer: {
            Text("Saved only on this phone. Swipe left to remove.")
        }
    }
}

private struct SuggestionRow: View {
    let walk: WalkSuggestion
    let reachesGoal: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(walk.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("\(walk.meters / 1000, format: .number.precision(.fractionLength(1))) km · \(walk.minutes) min · ~\(walk.steps.formatted()) steps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if reachesGoal {
                        Text("Reaches your goal")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.brand, in: Capsule())
                    }
                    if walk.isEstimate {
                        Text("Estimated")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }
            }
            Spacer()
            Image(systemName: isSelected ? "map.fill" : "map")
                .foregroundStyle(isSelected ? Color.brand : .secondary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    RoutesView().environmentObject(StepStore())
}
