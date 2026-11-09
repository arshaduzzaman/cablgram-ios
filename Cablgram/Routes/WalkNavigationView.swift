import SwiftUI
import MapKit
import GoogleMaps

/// A walk in Cablgram colours: a pink banner on top, the map following you,
/// and live steps toward your reward at the bottom.
struct WalkNavigationView: View {
    @StateObject private var session: WalkSession
    @EnvironmentObject private var steps: StepStore
    let onEnd: (Int) -> Void

    /// Steps still needed for the reward when the walk started.
    @State private var stepsToGoalAtStart = 0
    @State private var lastMilestone = 0

    init(onEnd: @escaping (Int) -> Void) {
        _session = StateObject(wrappedValue: WalkSession())
        self.onEnd = onEnd
    }

    private var stepsLeftForReward: Int { max(stepsToGoalAtStart - session.walkedSteps, 0) }

    var body: some View {
        ZStack(alignment: .top) {
            map.ignoresSafeArea()

            banner
                .padding(.horizontal, 12)
                .padding(.top, 6)

            VStack {
                Spacer()
                bottomCard
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .task {
            stepsToGoalAtStart = steps.stepsToGoal
            await session.start()
        }
        .onDisappear { session.stop() }
        .onChange(of: session.walkedSteps) { _, walked in
            // A little buzz every 500 steps, and a celebration if this walk unlocks the reward.
            let milestone = walked / 500
            if milestone > lastMilestone {
                lastMilestone = milestone
                Haptics.success()
            }
            if stepsToGoalAtStart > 0, walked >= stepsToGoalAtStart, walked - 1 < stepsToGoalAtStart {
                Haptics.celebrate()
            }
        }
    }

    // MARK: - Map

    @ViewBuilder
    private var map: some View {
        if GoogleMapsConfig.isEnabled {
            NavGoogleMap(location: session.location, heading: session.heading)
        } else {
            NavAppleMap()
        }
    }

    // MARK: - Banner

    private var banner: some View {
        HStack(spacing: 14) {
            Image(systemName: "figure.walk")
                .font(.system(size: 30, weight: .bold))
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Walking")
                    .font(.title2.weight(.bold))
                Text("Walk anywhere. Every step counts toward your reward.")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .opacity(0.95)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(Color.brand, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    // MARK: - Bottom card

    private var bottomCard: some View {
        VStack(spacing: 16) {
            Capsule().fill(Color(.systemFill)).frame(width: 36, height: 5)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.walkedSteps.formatted())
                        .font(.system(size: 44, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: session.walkedSteps)
                    Text("steps this walk")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if session.walkedMeters > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Self.distance(session.walkedMeters))
                            .font(.title3.weight(.bold))
                        Text(session.startDate, style: .timer)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                }
            }

            if let goal = steps.goalReward {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        RewardImage(reward: goal)
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text(stepsLeftForReward == 0
                             ? "**\(goal.fullName)** unlocked! 🎉"
                             : "**\(stepsLeftForReward.formatted())** steps to \(goal.fullName)")
                            .font(.subheadline)
                            .monospacedDigit()
                        Spacer()
                    }
                    let done = Double(goal.steps - stepsLeftForReward) / Double(goal.steps)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.systemFill))
                            Capsule().fill(Color.brand)
                                .frame(width: max(8, geo.size.width * min(max(done, 0), 1)))
                                .animation(.spring(duration: 0.5), value: done)
                        }
                    }
                    .frame(height: 8)
                }
            }

            Button {
                Haptics.warning()
                onEnd(session.walkedSteps)
            } label: {
                Text("End walk")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.black, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 34)
        .background(Color(.systemBackground),
                    in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 18, y: -4)
    }

    // MARK: - Formatting

    static func distance(_ meters: Double) -> String {
        if meters < 1_000 { return "\(Int((meters / 10).rounded() * 10)) m" }
        return String(format: "%.1f km", meters / 1_000)
    }
}

/// The pink "you are here" puck with a direction arrow.
private struct UserPuck: View {
    var body: some View {
        ZStack {
            Circle().fill(.white).frame(width: 34, height: 34)
            Circle().fill(Color.brand).frame(width: 26, height: 26)
            Image(systemName: "location.north.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
        .padding(6)
    }
}

/// Black-and-white Google map that follows you, tilted.
private struct NavGoogleMap: UIViewRepresentable {
    let location: CLLocation?
    let heading: CLLocationDirection

    @Environment(\.displayScale) private var displayScale

    final class Coordinator {
        let puck = GMSMarker()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> GMSMapView {
        let options = GMSMapViewOptions()
        options.camera = GMSCameraPosition(latitude: 23.75, longitude: 90.39, zoom: 16)
        let map = GMSMapView(options: options)
        map.mapStyle = try? GMSMapStyle(jsonString: GoogleMapsConfig.monochromeStyle)
        map.isBuildingsEnabled = true
        map.settings.compassButton = false
        map.settings.tiltGestures = false
        map.padding = UIEdgeInsets(top: 150, left: 0, bottom: 290, right: 0)

        let renderer = ImageRenderer(content: UserPuck())
        renderer.scale = displayScale
        context.coordinator.puck.icon = renderer.uiImage
        context.coordinator.puck.groundAnchor = CGPoint(x: 0.5, y: 0.5)
        context.coordinator.puck.isFlat = true
        context.coordinator.puck.zIndex = 10
        return map
    }

    func updateUIView(_ map: GMSMapView, context: Context) {
        guard let location else { return }
        let puck = context.coordinator.puck
        puck.position = location.coordinate
        puck.rotation = heading
        puck.map = map
        map.animate(to: GMSCameraPosition(target: location.coordinate, zoom: 17.5,
                                          bearing: heading, viewingAngle: 50))
    }
}

/// Apple Maps fallback when there's no Google key.
private struct NavAppleMap: View {
    @State private var camera: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
    }
}
