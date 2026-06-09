import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Google Sign-In via the native OAuth 2.0 + PKCE web flow — no third-party SDK.
/// Needs only an iOS OAuth **client ID** (created in Google Cloud Console; no
/// client secret for installed apps). Returns the Google ID token, which the
/// backend verifies to identify the user.
///
/// Set the client ID in the app's Settings; it's stored in AppConfig.
enum GoogleAuthError: LocalizedError {
    case notConfigured
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Google sign-in isn't set up yet. Add your OAuth Client ID in Settings."
        case .cancelled: return "Sign-in cancelled."
        case let .failed(m): return m
        }
    }
}

struct GoogleIdentity {
    let idToken: String
    let sub: String
    let email: String
    let name: String
    let picture: String?
}

@MainActor
final class GoogleAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleAuth()

    /// `123-abc.apps.googleusercontent.com` → reversed scheme used as the
    /// OAuth redirect for iOS clients.
    private func reversedScheme(_ clientID: String) -> String {
        let base = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(base)"
    }

    func signIn() async throws -> GoogleIdentity {
        let clientID = AppConfig.googleClientID
        guard !clientID.isEmpty else { throw GoogleAuthError.notConfigured }

        let scheme = reversedScheme(clientID)
        let redirectURI = "\(scheme):/oauth2redirect"
        let verifier = Self.randomURLSafe(64)
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomURLSafe(24)

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "prompt", value: "select_account"),
        ]

        let callbackURL = try await runSession(url: comps.url!, scheme: scheme)
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw GoogleAuthError.failed("State mismatch — please try again.")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            let err = items.first(where: { $0.name == "error" })?.value ?? "No authorization code"
            throw GoogleAuthError.failed(err)
        }

        let idToken = try await exchange(code: code, verifier: verifier,
                                         clientID: clientID, redirectURI: redirectURI)
        return try Self.decodeIdentity(idToken)
    }

    // MARK: - Web session

    private func runSession(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, error in
                if let url { cont.resume(returning: url) }
                else if let error = error as? ASWebAuthenticationSessionError,
                        error.code == .canceledLogin {
                    cont.resume(throwing: GoogleAuthError.cancelled)
                } else {
                    cont.resume(throwing: GoogleAuthError.failed(error?.localizedDescription ?? "Sign-in failed"))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.first?.keyWindow ?? ASPresentationAnchor()
        }
    }

    // MARK: - Token exchange

    private func exchange(code: String, verifier: String,
                          clientID: String, redirectURI: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? "")" }
         .joined(separator: "&")
        req.httpBody = Data(body.utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = (obj?["error_description"] as? String) ?? "Token exchange failed"
            throw GoogleAuthError.failed(detail)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = obj["id_token"] as? String else {
            throw GoogleAuthError.failed("No ID token in response")
        }
        return idToken
    }

    // MARK: - PKCE + JWT helpers

    private static func randomURLSafe(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncoded()
    }

    static func decodeIdentity(_ jwt: String) throws -> GoogleIdentity {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3,
              let payload = Data(base64URLEncoded: String(parts[1])),
              let obj = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let sub = obj["sub"] as? String else {
            throw GoogleAuthError.failed("Could not read Google identity token")
        }
        return GoogleIdentity(
            idToken: jwt,
            sub: sub,
            email: obj["email"] as? String ?? "",
            name: obj["name"] as? String ?? (obj["email"] as? String ?? "Signed in"),
            picture: obj["picture"] as? String
        )
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "&=+")
        return cs
    }()
}
