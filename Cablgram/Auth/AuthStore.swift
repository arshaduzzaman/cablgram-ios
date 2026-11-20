import SwiftUI
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import GoogleSignIn

/// Sign-in through Firebase Auth (same Firebase project as the website): with a phone
/// number and a texted code only. Accounts that linked Google before keep it, but
/// nobody signs in with Google any more (the SDK only stays to sign it out). Before
/// using the app everyone also needs a name (always typed by hand), a verified phone
/// number and a date of birth (`users/{uid}.dateOfBirth`), all changeable later in the
/// Menu tab. Android does the same.
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

    #if DEBUG
    /// Lets you into the app before Firebase is set up (debug builds only).
    @Published var skippedSignIn = false
    #endif

    /// Date of birth from `users/{uid}`, nil until it's given.
    @Published private(set) var dateOfBirth: Date?
    /// Whether `users/{uid}` has been read yet (so the profile screen doesn't flash).
    @Published private(set) var profileLoaded = false

    private var listener: AuthStateDidChangeListenerHandle?
    private var profileListener: ListenerRegistration?

    init() {
        #if DEBUG
        // `-skipSignIn` launch argument: open the app without signing in, for
        // checking screens in the Simulator. Debug builds only.
        if ProcessInfo.processInfo.arguments.contains("-skipSignIn") { skippedSignIn = true }
        #endif
        guard Self.isConfigured else { return }
        user = Auth.auth().currentUser
        listener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                guard let self else { return }
                let changed = self.user?.uid != user?.uid
                self.user = user
                if changed || self.profileListener == nil { self.listenToProfile() }
            }
        }
        listenToProfile()
    }

    private func listenToProfile() {
        profileListener?.remove()
        profileListener = nil
        dateOfBirth = nil
        guard let uid = user?.uid else {
            profileLoaded = false
            return
        }
        profileLoaded = false
        profileListener = Firestore.firestore().collection("users").document(uid)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self, self.user?.uid == uid else { return }
                    if let snapshot {
                        self.dateOfBirth = (snapshot.data()?["dateOfBirth"] as? String).flatMap(Self.birthFormat.date(from:))
                        self.profileLoaded = true
                    } else if error != nil {
                        // Offline with nothing cached: don't lock people out.
                        self.profileLoaded = true
                    }
                }
            }
    }

    // MARK: - Profile

    /// Still missing something the app needs before you can use it.
    var needsProfile: Bool {
        guard user != nil else { return false }
        return !hasName || user?.phoneNumber == nil || dateOfBirth == nil
    }

    var hasName: Bool { !(user?.displayName ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    var phoneNumber: String? { user?.phoneNumber }

    /// "YYYY-MM-DD", the same on Android and in the dashboard.
    static let birthFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func saveName(_ name: String) async throws {
        guard let user else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProfileError.message("Type your name.") }
        let change = user.createProfileChangeRequest()
        change.displayName = name
        try await change.commitChanges()
        try await Firestore.firestore().collection("users").document(user.uid).setData(Self.profileFields(["name": name]), merge: true)
        await reloadUser()
    }

    func saveDateOfBirth(_ date: Date) async throws {
        guard let user else { return }
        // Written from the picker's calendar day, not a moment in time.
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let text = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        try await Firestore.firestore().collection("users").document(user.uid)
            .setData(Self.profileFields(["dateOfBirth": text]), merge: true)
        dateOfBirth = Self.birthFormat.date(from: text)
    }

    /// The rules want every write to `users/{uid}` to say which platform and when.
    private static func profileFields(_ fields: [String: Any]) -> [String: Any] {
        fields.merging(["platform": "ios", "lastSeen": FieldValue.serverTimestamp()]) { new, _ in new }
    }

    /// Picks up changes to the signed-in account (name, phone).
    func reloadUser() async {
        try? await Auth.auth().currentUser?.reload()
        // A fresh token carries the new phone number, which the rules check.
        _ = try? await Auth.auth().currentUser?.getIDTokenResult(forcingRefresh: true)
        user = Auth.auth().currentUser
        UserProfile.sync(force: true)
    }

    // MARK: - Phone

    enum PhoneUse {
        /// Sign in (or create an account) with the number.
        case signIn
        /// Add the number to the account you're signed in with.
        case link
        /// Replace the account's number.
        case change
    }

    /// Bangladeshi numbers typed any common way (01712…, 1712…, 8801712…, +8801712…)
    /// as +8801712…; nil if it can't be one.
    static func normalizedPhone(_ typed: String) -> String? {
        var digits = typed.filter(\.isNumber)
        if digits.hasPrefix("880") { digits.removeFirst(3) }
        if digits.hasPrefix("0") { digits.removeFirst() }
        guard digits.count == 10, digits.hasPrefix("1") else { return nil }
        return "+880" + digits
    }

    /// Texts a code to `phone` (already normalized). Returns the id to verify it with.
    func sendCode(to phone: String) async throws -> String {
        guard Self.isConfigured else { throw ProfileError.message("Sign-in isn't set up yet.") }
        do {
            return try await PhoneAuthProvider.provider().verifyPhoneNumber(phone, uiDelegate: nil)
        } catch {
            throw ProfileError.message(Self.friendly(error))
        }
    }

    /// Checks the texted code and signs in, adds or changes the number.
    func verify(code: String, id: String, use: PhoneUse) async throws {
        let credential = PhoneAuthProvider.provider().credential(withVerificationID: id, verificationCode: code)
        do {
            switch use {
            case .signIn:
                try await Auth.auth().signIn(with: credential)
            case .link:
                guard let user else { return }
                try await user.link(with: credential)
            case .change:
                guard let user else { return }
                try await user.updatePhoneNumber(credential)
            }
            await reloadUser()
            Haptics.success()
        } catch {
            Haptics.error()
            throw ProfileError.message(Self.friendly(error))
        }
    }

    private static func friendly(_ error: Error) -> String {
        let code = AuthErrorCode(rawValue: (error as NSError).code)
        switch code {
        case .invalidPhoneNumber, .missingPhoneNumber: return "That doesn't look like a phone number."
        case .invalidVerificationCode, .missingVerificationCode: return "That code isn't right. Check the text and try again."
        case .sessionExpired, .invalidVerificationID: return "That code has expired. Send a new one."
        case .tooManyRequests: return "Too many tries. Wait a while and try again."
        case .quotaExceeded: return "Can't send texts right now. Try again later."
        case .credentialAlreadyInUse, .accountExistsWithDifferentCredential:
            return "That number is already used by another Cablgram account."
        case .providerAlreadyLinked: return "This account already has a phone number."
        case .requiresRecentLogin: return "For safety, sign out and back in, then try again."
        case .networkError: return "No internet connection."
        case .webContextCancelled: return "Verification was cancelled."
        default: return error.localizedDescription
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

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        try? Auth.auth().signOut()
        profileListener?.remove()
        profileListener = nil
        dateOfBirth = nil
        profileLoaded = false
        #if DEBUG
        skippedSignIn = false
        #endif
    }
}

/// A message to show as is.
enum ProfileError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}
