import Foundation

/// Where the app finds the FastAPI backend. Defaults to the always-on Render
/// deployment (which reads the same Neon database), so the app works out of the
/// box on any device with no local server. Override it in the in-app Settings to
/// point at a local dev backend (http://127.0.0.1:8011 in the simulator) or a
/// self-hosted one.
enum AppConfig {
    private static let key = "api.baseURL"
    static let defaultBaseURL = "https://ai-stock-studio.onrender.com"

    static var baseURL: String {
        get {
            let v = UserDefaults.standard.string(forKey: key) ?? defaultBaseURL
            return v.isEmpty ? defaultBaseURL : v
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            UserDefaults.standard.set(trimmed, forKey: key)
        }
    }

    /// Google OAuth **iOS client ID** (e.g. 123-abc.apps.googleusercontent.com).
    /// Created in Google Cloud Console; required for real Google sign-in. Empty
    /// until you paste it in Settings.
    private static let googleClientIDKey = "auth.googleClientID"
    private static let defaultGoogleClientID = "400966257954-dadvqu0a25dfk6cq4njl2j9cuuibaad3.apps.googleusercontent.com"

    static var googleClientID: String {
        get {
            let v = UserDefaults.standard.string(forKey: googleClientIDKey) ?? ""
            return v.isEmpty ? defaultGoogleClientID : v
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces),
                                        forKey: googleClientIDKey) }
    }
}
