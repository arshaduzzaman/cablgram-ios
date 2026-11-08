import SwiftUI
import FirebaseCore
import FirebaseAuth
import GoogleSignIn

/// Google sign-in through Firebase Auth (same Firebase project as the website).
@MainActor
final class AuthStore: ObservableObject {
    /// True once GoogleService-Info.plist is in the app.
    static let isConfigured = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil

    static func configureFirebase() {
        if isConfigured && FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
    }

    @Published private(set) var user: FirebaseAuth.User?
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    #if DEBUG
    /// Lets you into the app before Firebase is set up (debug builds only).
    @Published var skippedSignIn = false
    #endif

    private var listener: AuthStateDidChangeListenerHandle?

    init() {
        guard Self.isConfigured else { return }
        user = Auth.auth().currentUser
        listener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.user = user }
        }
    }

    var canEnterApp: Bool {
        #if DEBUG
        return user != nil || skippedSignIn
        #else
        return user != nil
        #endif
    }

    var displayName: String { user?.displayName ?? "Walker" }

    func signInWithGoogle() async {
        guard Self.isConfigured, let clientID = FirebaseApp.app()?.options.clientID else {
            errorMessage = "Sign-in isn't set up yet: GoogleService-Info.plist is missing."
            return
        }
        guard let presenter = Self.topViewController() else { return }

        isWorking = true
        defer { isWorking = false }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else {
                errorMessage = "Google didn't return an ID token. Try again."
                return
            }
            let credential = GoogleAuthProvider.credential(withIDToken: idToken,
                                                           accessToken: result.user.accessToken.tokenString)
            try await Auth.auth().signIn(with: credential)
            errorMessage = nil
        } catch let error as NSError where error.domain == kGIDSignInErrorDomain
                    && error.code == GIDSignInError.canceled.rawValue {
            // The user closed the Google sheet; nothing to report.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        try? Auth.auth().signOut()
        #if DEBUG
        skippedSignIn = false
        #endif
    }

    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
