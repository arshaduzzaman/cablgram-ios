import SwiftUI
import UserNotifications
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging

/// Push notifications (Firebase Cloud Messaging) plus the `users/{uid}` profile the
/// admin dashboard reads. Android writes the same fields.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AuthStore.configureFirebase()
        UNUserNotificationCenter.current().delegate = self
        guard AuthStore.isConfigured else { return true }
        Messaging.messaging().delegate = self
        // Gets an APNs token even before the user allows alerts; alerts only show once they do.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        Task { @MainActor in
            UserProfile.fcmToken = fcmToken
            UserProfile.sync(force: true)
        }
    }

    /// Shows notifications as banners even while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Tapping a notification can open a tab: the dashboard sends `tab` = news, walk, discover or menu.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let tab = (response.notification.request.content.userInfo["tab"] as? String).flatMap(AppTab.init(rawValue:))
        await MainActor.run { PushRouter.shared.openTab = tab }
    }
}

/// Carries "open this tab" from a tapped notification to `MainView`.
@MainActor
final class PushRouter: ObservableObject {
    static let shared = PushRouter()
    @Published var openTab: AppTab?
}

enum Push {
    /// Asks once to allow notifications (iOS remembers the answer), then refreshes the profile.
    @MainActor
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        UIApplication.shared.registerForRemoteNotifications()
        UserProfile.sync(force: true)
    }
}

/// Keeps `users/{uid}` up to date: who you are, which phone and app version, your push
/// token and when you last opened the app. Only the admin dashboard reads it.
@MainActor
enum UserProfile {
    static var fcmToken: String?
    private static var lastSync: Date?
    private static var lastKey: String?

    static func sync(force: Bool = false) {
        guard AuthStore.isConfigured, let user = Auth.auth().currentUser else { return }
        let key = "\(user.uid)|\(fcmToken ?? "")"
        // At most every 10 minutes unless something changed.
        if !force, key == lastKey, let last = lastSync, Date().timeIntervalSince(last) < 600 { return }
        lastKey = key
        lastSync = Date()

        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let allowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            let info = Bundle.main.infoDictionary
            var data: [String: Any] = [
                "name": user.displayName ?? "Walker",
                "email": user.email ?? "",
                "platform": "ios",
                "appVersion": info?["CFBundleShortVersionString"] as? String ?? "",
                "build": info?["CFBundleVersion"] as? String ?? "",
                "osVersion": UIDevice.current.systemVersion,
                "device": deviceModel(),
                "notifications": allowed,
                "timezone": TimeZone.current.identifier,
                "lastSeen": FieldValue.serverTimestamp(),
            ]
            if let photo = user.photoURL?.absoluteString { data["photoURL"] = photo }
            if let fcmToken { data["fcmToken"] = fcmToken }
            try? await Firestore.firestore().collection("users").document(user.uid).setData(data, merge: true)
        }
    }

    /// e.g. "iPhone16,1".
    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
