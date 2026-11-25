import SwiftUI
import CoreMotion

/// After the profile, before the app: makes sure Cablgram can really read your steps.
/// Health doesn't say whether it gave access, so this looks for actual steps: in Health,
/// and on the iPhone's motion chip to tell "Steps is off in Health" from "no steps yet".
struct StepSetupView: View {
    @EnvironmentObject private var steps: StepStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    let onDone: () -> Void
    /// Lets someone in without steps for now (they're asked again next launch).
    let onSkip: () -> Void

    @State private var result: StepStore.Check?
    @State private var checking = false
    /// Today's motion-chip steps when the walk test started.
    @State private var walkStart: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Turn on step counting").font(.largeTitle.bold())
                    Text("Your steps unlock rewards and move you in races, so let's check Cablgram can read them.")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)

                statusCard

                if let result, result != .working, result != .unavailable {
                    fixes(for: result)
                }

                primaryButton

                if result != .working && result != .unavailable && result != nil {
                    Button("Not now", action: onSkip)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
        .task { await runCheck() }
        // Back from the Health app or Settings: check again.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, result != .working { Task { await runCheck() } }
        }
        // While waiting on steps, keep looking every few seconds.
        .task(id: result) {
            guard result == .healthOff || result == .noSteps else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                await runCheck(quiet: true)
            }
        }
        .onChange(of: steps.pedometerToday) { _, now in
            if walkStart == nil { walkStart = now }
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                switch result {
                case nil:
                    ProgressView()
                case .working, .unavailable:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .healthOff, .motionOff:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .noSteps:
                    Image(systemName: "figure.walk").foregroundStyle(Color.brand)
                }
            }
            .font(.title2)
            .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                if result == .noSteps || result == .healthOff, let walked {
                    Text("\(walked.formatted()) steps counted on this iPhone so far")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.brand)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(walked)))
                        .animation(.snappy, value: walked)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Steps walked on the motion chip since this screen opened.
    private var walked: Int? {
        walkStart.map { max(steps.pedometerToday - $0, 0) }
    }

    private var title: String {
        switch result {
        case nil: "Checking your steps…"
        case .working: "Step counting works"
        case .unavailable: "No Apple Health on this device"
        case .healthOff: "Cablgram can't read your steps"
        case .motionOff: "Motion & Fitness is off"
        case .noSteps: "No steps yet"
        }
    }

    private var detail: String {
        switch result {
        case nil: "Looking for your steps in Apple Health."
        case .working: "Your steps are coming through from Apple Health."
        case .unavailable: "You can still use Cablgram, but steps won't count on this device."
        case .healthOff: "Your iPhone is counting steps, but Health isn't sharing them with Cablgram."
        case .motionOff: "Your iPhone needs Motion & Fitness to count steps for Cablgram."
        case .noSteps: "Walk around for a minute with your iPhone. This screen moves on once Health has your steps."
        }
    }

    // MARK: - Fixes

    @ViewBuilder
    private func fixes(for result: StepStore.Check) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How to fix it").font(.headline)
            switch result {
            case .healthOff:
                step(1, "Open the **Health** app and tap your picture at the top right.")
                step(2, "Tap **Apps**, then **Cablgram**.")
                step(3, "Turn on **Steps**, then come back here.")
                Text("Just walked? Steps can take a minute to show up in Health.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .motionOff:
                step(1, "Open **Settings** below.")
                step(2, "Turn on **Motion & Fitness**, then come back here.")
            case .noSteps:
                step(1, "In **Settings → Privacy & Security → Motion & Fitness**, turn on **Fitness Tracking** and **Health**.")
                step(2, "Then walk a little with your iPhone.")
            case .working, .unavailable:
                EmptyView()
            }
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.brand, in: Circle())
            Text(text).font(.subheadline)
        }
    }

    // MARK: - Button

    @ViewBuilder
    private var primaryButton: some View {
        switch result {
        case .working, .unavailable:
            bigButton("Continue") { onDone() }
        case .healthOff:
            bigButton("Open Health") { open("x-apple-health://") }
        case .motionOff, .noSteps:
            bigButton("Open Settings") { open(UIApplication.openSettingsURLString) }
        case nil:
            EmptyView()
        }
    }

    private func bigButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.brand, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { openURL(url) }
    }

    // MARK: - Check

    private func runCheck(quiet: Bool = false) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        if !quiet { result = nil }
        let found = await steps.check()
        if found == .working, result != .working { Haptics.success() }
        withAnimation(.snappy) { result = found }
    }
}
