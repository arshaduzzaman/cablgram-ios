import SwiftUI
import GoogleSignIn

@main
struct CablgramApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var auth: AuthStore
    @StateObject private var steps = StepStore()
    @StateObject private var leaderboard = LeaderboardStore()

    init() {
        // Firebase must be set up before AuthStore reads the current user.
        AuthStore.configureFirebase()
        GoogleMapsConfig.activate()
        _auth = StateObject(wrappedValue: AuthStore())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.canEnterApp {
                    MainView()
                } else {
                    SignInView()
                }
            }
            .environmentObject(auth)
            .environmentObject(steps)
            .environmentObject(leaderboard)
            .tint(.brand)
            .preferredColorScheme(.light)
            // Keep users/{uid} fresh for the admin dashboard.
            .onChange(of: auth.user?.uid, initial: true) { UserProfile.sync(force: true) }
            .onChange(of: scenePhase) { if scenePhase == .active { UserProfile.sync() } }
            .onOpenURL { url in
                // Returns from the Google sign-in page.
                GIDSignIn.sharedInstance.handle(url)
            }
        }
    }
}
