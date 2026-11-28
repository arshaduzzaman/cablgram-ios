import SwiftUI
import GoogleSignIn
import FirebaseAuth

@main
struct CablgramApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var auth: AuthStore
    @StateObject private var steps = StepStore()
    @StateObject private var leaderboard = LeaderboardStore()
    /// The step check on `StepSetupView` passed once on this phone.
    @AppStorage("setup.stepsChecked") private var stepsChecked = false
    /// "Not now" on the step check: asked again next launch.
    @State private var skippedStepCheck = false
    @ObservedObject private var config = AppConfig.shared

    init() {
        // Firebase is set up in AppDelegate.didFinishLaunching, not here: this runs before
        // iOS has created the app, and Firebase Auth then skips setting up phone sign-in
        // (ERROR_NOTIFICATION_NOT_FORWARDED). The stores below are created lazily, when the
        // first screen is built, which is after didFinishLaunching.
        GoogleMapsConfig.activate()
        _auth = StateObject(wrappedValue: AuthStore())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if config.mustUpdate {
                    UpdateRequiredView()
                } else if !auth.canEnterApp {
                    SignInView()
                } else if auth.user != nil && !auth.profileLoaded {
                    ZStack {
                        Color.brand.ignoresSafeArea()
                        ProgressView().tint(.white)
                    }
                } else if auth.needsProfile {
                    ProfileGateView()
                } else if !stepsChecked && !skippedStepCheck {
                    StepSetupView(onDone: { withAnimation { stepsChecked = true } },
                                  onSkip: { withAnimation { skippedStepCheck = true } })
                } else {
                    MainView()
                }
            }
            .environmentObject(auth)
            .environmentObject(steps)
            .environmentObject(leaderboard)
            .tint(.brand)
            .preferredColorScheme(.light)
            .modifier(UpdatePrompt())
            .task { await config.refresh(force: true) }
            // Keep users/{uid} fresh for the admin dashboard.
            .onChange(of: auth.user?.uid, initial: true) {
                UserProfile.sync(force: true)
                LocationTracker.shared.refreshArea(force: true)
            }
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    Task { await config.refresh() }
                    UserProfile.sync()
                    LocationTracker.shared.refreshArea()
                }
            }
            .onOpenURL { url in
                // Returns from the phone check (reCAPTCHA).
                if AuthStore.isConfigured, Auth.auth().canHandle(url) { return }
                GIDSignIn.sharedInstance.handle(url)
            }
        }
    }
}
