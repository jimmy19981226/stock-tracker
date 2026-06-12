import Foundation
import SwiftUI

struct AuthUser: Codable, Equatable {
    let name: String
    let email: String
    let picture: String?
    let provider: String   // "google" | "guest"

    var isGuest: Bool { provider == "guest" }
    var initials: String {
        let source = name.isEmpty ? email : name
        let parts = source.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }
}

enum AuthState: Equatable {
    case loading
    case signedOut
    case signedIn(AuthUser)
}

/// Owns the sign-in state and gates the whole app. The Google ID token lives in
/// the Keychain (and is attached to every API request by APIClient); the user
/// profile is cached in UserDefaults so the app reopens already signed in.
@MainActor
final class AuthStore: ObservableObject {
    nonisolated static let tokenKey = "auth.idToken"
    nonisolated static let refreshTokenKey = "auth.refreshToken"
    private static let userKey = "auth.user"

    @Published private(set) var state: AuthState = .loading
    @Published var errorMessage: String?
    @Published var isSigningIn = false

    init() { restore() }

    var user: AuthUser? {
        if case let .signedIn(u) = state { return u }
        return nil
    }

    private func restore() {
        if let data = UserDefaults.standard.data(forKey: Self.userKey),
           let user = try? JSONDecoder().decode(AuthUser.self, from: data) {
            state = .signedIn(user)
        } else {
            state = .signedOut
        }
    }

    func signInWithGoogle() async {
        errorMessage = nil
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let identity = try await GoogleAuth.shared.signIn()
            Keychain.set(identity.idToken, for: Self.tokenKey)
            // Keep any previously stored refresh token if Google didn't send one.
            if let refresh = identity.refreshToken, !refresh.isEmpty {
                Keychain.set(refresh, for: Self.refreshTokenKey)
            }
            let user = AuthUser(name: identity.name, email: identity.email,
                                picture: identity.picture, provider: "google")
            persist(user)
        } catch GoogleAuthError.cancelled {
            // user backed out — no error banner
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Use the app without Google for now (single-user / before OAuth is set up).
    func continueAsGuest() {
        persist(AuthUser(name: "Guest", email: "", picture: nil, provider: "guest"))
    }

    func signOut() {
        Keychain.remove(Self.tokenKey)
        Keychain.remove(Self.refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.userKey)
        state = .signedOut
    }

    private func persist(_ user: AuthUser) {
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: Self.userKey)
        }
        state = .signedIn(user)
    }
}
