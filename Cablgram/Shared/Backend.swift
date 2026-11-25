import Foundation

/// Where the app's server (cablgram-admin: step recounts, reward claims, friends) lives.
///
/// Release builds always use the deployed one. Debug builds use `ADMIN_BASE_URL` from the
/// git-ignored Secrets.xcconfig when it's set, so you can test against a dashboard running
/// on your Mac (see Secrets.example.xcconfig).
enum Backend {
    private static let production = URL(string: "https://cablgram-admin.vercel.app")!

    static let base: URL = {
        #if DEBUG
        if let text = (Bundle.main.object(forInfoDictionaryKey: "AdminBaseURL") as? String)?
            .trimmingCharacters(in: .whitespaces),
           !text.isEmpty, let url = URL(string: text), url.scheme != nil, url.host != nil {
            print("Backend: using \(url.absoluteString) (ADMIN_BASE_URL)")
            return url
        }
        #endif
        return production
    }()

    #if DEBUG
    /// Debug builds with `AUTH_TEST_NUMBERS_ONLY = YES` in Secrets.xcconfig: only Firebase's test
    /// phone numbers can sign in (no silent push or "not a robot" check), for the Simulator.
    static let testNumbersOnly = (Bundle.main.object(forInfoDictionaryKey: "AuthTestNumbersOnly") as? String) == "YES"
    #endif

    /// `Backend.url("/api/friends")`
    static func url(_ path: String) -> URL {
        URL(string: path, relativeTo: base)!.absoluteURL
    }
}
