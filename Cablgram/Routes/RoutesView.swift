import SwiftUI

/// Full-screen map of your usual places, with a bottom panel of walks that
/// reach today's step goal.
struct RoutesView: View {
    @EnvironmentObject private var steps: StepStore
    @StateObject private var places = PlacesStore()
    @StateObject private var planner = RoutePlanner()
    @StateObject private var location = LocationTracker()

    @AppStorage("walk.dailyGoal") private var dailyGoal = 8_000
    @State private var selectedID: WalkSuggestion.ID?
    @State private var addingKind: SavedPlace.Kind?
    @State private var isExpanded = false

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
        GeometryReader { geo in
            let panelHeight = geo.size.height * (isExpanded ? 0.74 : 0.44)

            ZStack(alignment: .top) {
                RouteMap(places: places.places, walk: selected, bottomInset: panelHeight)
                    .ignoresSafeArea(edges: .top)

                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                VStack {
                    Spacer()
                    panel.frame(height: panelHeight)
                }
            }
            .animation(.spring(duration: 0.35), value: isExpanded)
        }
        .sheet(item: $addingKind) { kind in
            AddPlaceView(initialKind: kind, currentLocation: location.lastLocation) { place in
                places.add(place)
            }
            .presentationDetents([.large])
        }
        .task(id: places.places) {
            selectedID = nil
            await planner.plan(home: places.home, destinations: places.destinations)
        }
        .onAppear { location.requestOnce() }
    }

    // MARK: - Floating top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(Color.brand.opacity(0.2), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: min(Double(steps.stepsToday) / Double(dailyGoal), 1))
                        .stroke(.brandGradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(steps.stepsToday.formatted()) / \(dailyGoal.formatted())")
                        .font(.subheadline.bold().monospacedDigit())
                    Text(stepsNeeded == 0 ? "Goal reached 🎉" : "\(stepsNeeded.formatted()) steps to go")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)

            Spacer()

            Button { addingKind = places.home == nil ? .home : .other } label: {
                Image(systemName: "plus")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.brandGradient, in: Circle())
                    .shadow(color: Color.brand.opacity(0.35), radius: 8, y: 3)
            }
            .accessibilityLabel("Add a place")
        }
    }

    // MARK: - Bottom panel

    private var panel: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 40, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .onTapGesture { isExpanded.toggle() }
                .gesture(
                    DragGesture(minimumDistance: 10).onEnded { value in
                        if value.translation.height < -40 { isExpanded = true }
                        if value.translation.height > 40 { isExpanded = false }
                    }
                )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    goalRow
                    suggestionsBlock
                    placesBlock
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground),
                    in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 16, y: -2)
    }

    private var goalRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Daily goal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text("\(dailyGoal.formatted()) steps")
                    .font(.title3.bold().monospacedDigit())
                    .contentTransition(.numericText())
            }
            Spacer()
            HStack(spacing: 8) {
                roundButton("minus") { dailyGoal = max(2_000, dailyGoal - 1_000) }
                roundButton("plus") { dailyGoal = min(30_000, dailyGoal + 1_000) }
            }
        }
        .animation(.snappy, value: dailyGoal)
    }

    private func roundButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.bold())
                .frame(width: 36, height: 36)
                .background(Color(.secondarySystemBackground), in: Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var suggestionsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ways to reach your goal").font(.headline)

            if places.home == nil {
                emptyPrompt("Set your home to get walk ideas", systemImage: "house.fill") { addingKind = .home }
            } else if places.destinations.isEmpty {
                emptyPrompt("Add places you go often", systemImage: "mappin.and.ellipse") { addingKind = .other }
            } else if planner.isPlanning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finding walking routes…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(ranked) { walk in
                    SuggestionCard(walk: walk,
                                   reachesGoal: stepsNeeded > 0 && walk.steps >= stepsNeeded,
                                   isSelected: walk.id == selectedID)
                        .onTapGesture {
                            selectedID = selectedID == walk.id ? nil : walk.id
                            if selectedID != nil { isExpanded = false }
                        }
                }
            }

            if stepsNeeded > 0 {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                    Text("Taking a rickshaw or bus? Get off 1 km early and walk the rest: about **+1,300 steps**.")
                        .font(.subheadline)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if planner.suggestions.contains(where: \.isEstimate) {
                Text("Dashed lines are straight-line estimates where no walking route was found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = planner.googleError {
                Text("Google Maps: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func emptyPrompt(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.brand)
    }

    private var placesBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your places").font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(places.places) { place in
                        Label(place.name, systemImage: place.kind.systemImage)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                            .contextMenu {
                                Button(role: .destructive) { places.remove(place) } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                    Button { addingKind = places.home == nil ? .home : .other } label: {
                        Label("Add", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.brand.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.brand)
                }
            }

            Text("Saved only on this phone. Long-press a place to remove it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            #if DEBUG
            Button("Load sample Dhaka places (debug)") { places.addSampleDhakaPlaces() }
                .font(.caption)
            #endif
        }
    }
}

private struct SuggestionCard: View {
    let walk: WalkSuggestion
    let reachesGoal: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(walk.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "map")
                    .foregroundStyle(isSelected ? Color.brand : .secondary)
            }

            HStack(spacing: 16) {
                metric("figure.walk", "~\(walk.steps.formatted())")
                metric("clock", "\(walk.minutes) min")
                metric("ruler", String(format: "%.1f km", walk.meters / 1000))
            }

            if reachesGoal || walk.isEstimate {
                HStack(spacing: 6) {
                    if reachesGoal {
                        tag("Reaches your goal", foreground: .white, background: AnyShapeStyle(.brandGradient))
                    }
                    if walk.isEstimate {
                        tag("Estimated", foreground: .secondary, background: AnyShapeStyle(Color(.tertiarySystemFill)))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.brand.opacity(0.08) : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelected ? Color.brand : .clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
    }

    private func metric(_ systemImage: String, _ text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }

    private func tag(_ text: String, foreground: Color, background: AnyShapeStyle) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
    }
}

#Preview {
    RoutesView().environmentObject(StepStore())
}
