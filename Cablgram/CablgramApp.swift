import SwiftUI
import GoogleSignIn

@main
struct CablgramApp: App {
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
            .onOpenURL { url in
                // Returns from the Google sign-in page.
                GIDSignIn.sharedInstance.handle(url)
            }
        }
    }
}
