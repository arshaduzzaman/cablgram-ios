import SwiftUI

/// Full-screen map of your usual places, opened from the Walk page, with a
/// bottom panel of walks toward your reward and a button to start walking.
/// Shares its places, routes and selected walk with the Walk page.
struct RoutesView: View {
    @Binding var selectedID: WalkSuggestion.ID?
    var onClose: () -> Void

    @EnvironmentObject private var steps: StepStore
    @EnvironmentObject private var places: PlacesStore
    @EnvironmentObject private var planner: RoutePlanner
    @EnvironmentObject private var location: LocationTracker

    @State private var addingKind: SavedPlace.Kind?
    @State private var isExpanded = false
    @State private var navigation: NavigationRequest?
    @State private var finishedSteps: Int?

    /// A walk to navigate. `walk` is nil for a free walk.
    struct NavigationRequest: Identifiable {
        let id = UUID()
        let walk: WalkSuggestion?
    }


    private var selected: WalkSuggestion? {
        planner.suggestions.first { $0.id == selectedID }
    }

    var body: some View {
        GeometryReader { geo in
            let panelHeight = geo.size.height * (isExpanded ? 0.74 : 0.42)

            ZStack(alignment: .top) {
                RouteMap(places: places.places, walk: selected, bottomInset: panelHeight)
                    .ignoresSafeArea(edges: .top)

                // Pink strip behind the status bar, so its white text stays readable.
                Color.clear
                    .frame(height: 0)
                    .frame(maxWidth: .infinity)
                    .background(Color.brand.ignoresSafeArea(edges: .top))

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
                Haptics.success()
            }
            .presentationDetents([.large])
        }
        .fullScreenCover(item: $navigation) { request in
            WalkNavigationView(walk: request.walk) { walked in
                navigation = nil
                finishedSteps = walked
                Task { await steps.refresh() }
            }
            .environmentObject(steps)
            .tint(.brand)
        }
        .alert("Nice walk! 🎉", isPresented: Binding(
            get: { finishedSteps != nil },
            set: { if !$0 { finishedSteps = nil } }
        )) {
            Button("Done") { finishedSteps = nil }
        } message: {
            if let walked = finishedSteps, let goal = steps.goalReward {
                Text("You walked \(walked.formatted()) steps. \(steps.stepsToGoal == 0 ? "\(goal.fullName) is ready to claim!" : "\(steps.stepsToGoal.formatted()) more to \(goal.fullName).")")
            } else {
                Text("You walked \(finishedSteps?.formatted() ?? "0") steps.")
            }
        }
    }

    // MARK: - Floating top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                Haptics.tap()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            }
            .accessibilityLabel("Close map")

            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(Color.brand.opacity(0.2), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: steps.goalReward.map { min(Double(steps.totalSteps) / Double($0.steps), 1) } ?? 1)
                        .stroke(Color.brand, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(steps.stepsToGoal == 0 ? "Ready to claim 🎉" : "\(steps.stepsToGoal.formatted()) steps")
                        .font(.subheadline.bold().monospacedDigit())
                    Text(steps.goalReward.map { "to \($0.fullName)" } ?? "All rewards claimed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)

            Spacer()

            Button {
                Haptics.tap()
                addingKind = places.home == nil ? .home : .other
            } label: {
                Image(systemName: "plus")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.brand, in: Circle())
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
                .onTapGesture {
                    Haptics.soft()
                    isExpanded.toggle()
                }
                .gesture(
                    DragGesture(minimumDistance: 10).onEnded { value in
                        if value.translation.height < -40, !isExpanded { Haptics.soft(); isExpanded = true }
                        if value.translation.height > 40, isExpanded { Haptics.soft(); isExpanded = false }
                    }
                )

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ways to reach your goal").font(.headline)

                    if places.home == nil {
                        prompt("Set your home to get walk ideas", systemImage: "house.fill") { addingKind = .home }
                    } else if places.destinations.isEmpty {
                        prompt("Add places you go often", systemImage: "mappin.and.ellipse") { addingKind = .other }
                    } else if planner.isPlanning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Finding walking routes…").foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        ForEach(planner.ranked(toGoal: steps.stepsToGoal)) { walk in
                            SuggestionCard(walk: walk,
                                           reachesGoal: steps.stepsToGoal > 0 && walk.steps >= steps.stepsToGoal,
                                           isSelected: walk.id == selectedID)
                                .onTapGesture {
                                    Haptics.select()
                                    selectedID = selectedID == walk.id ? nil : walk.id
                                    if selectedID != nil { isExpanded = false }
                                }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }

            startBar
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground),
                    in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 16, y: -2)
    }

    /// "Start this walk" for the selected route, or "Just walk" without one.
    private var startBar: some View {
        HStack(spacing: 10) {
            if let selected {
                Button {
                    Haptics.press()
                    navigation = NavigationRequest(walk: selected)
                } label: {
                    Label("Start this walk", systemImage: "location.north.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.brand, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    Haptics.press()
                    navigation = NavigationRequest(walk: nil)
                } label: {
                    Label("Just walk", systemImage: "figure.walk")
                        .font(.headline)
                        .foregroundStyle(Color.brand)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.brand.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color(.systemBackground))
        .animation(.snappy, value: selectedID)
    }

    private func prompt(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.brand)
    }
}

/// One suggested walk: stops, steps, time, distance.
struct SuggestionCard: View {
    let walk: WalkSuggestion
    let reachesGoal: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(walk.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "map")
                    .foregroundStyle(isSelected ? Color.brand : .secondary)
            }

            HStack(spacing: 14) {
                metric("figure.walk", "~\(walk.steps.formatted())")
                metric("clock", "\(walk.minutes) min")
                metric("ruler", String(format: "%.1f km", walk.meters / 1000))
            }

            HStack(spacing: 6) {
                if reachesGoal {
                    tag("Unlocks your reward", foreground: .white, background: AnyShapeStyle(Color.brand))
                }
                if walk.isEstimate {
                    tag("Estimated", foreground: .secondary, background: AnyShapeStyle(Color(.tertiarySystemFill)))
                }
            }
            .frame(minHeight: 20, alignment: .leading)
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
            .lineLimit(1)
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
