import Foundation

/// Hands out a currently-valid Google ID token for API requests. ID tokens
/// expire after ~1 hour, so this checks the JWT `exp` claim and transparently
/// trades the stored refresh token for a new one when needed — single-flight,
/// so a burst of parallel requests (e.g. PortfolioStore.loadAll) triggers at
/// most one refresh round-trip.
actor AuthTokenProvider {
    static let shared = AuthTokenProvider()

    private var refreshTask: Task<String?, Never>?

    /// The token to attach to a request, refreshed first if it's expired or
    /// about to be. Nil when signed out / guest. Falls back to the stale token
    /// when no refresh is possible so the server still gets a chance to answer.
    func validToken() async -> String? {
        guard let token = Keychain.get(AuthStore.tokenKey), !token.isEmpty else { return nil }
        guard Self.isExpiringSoon(token) else { return token }
        return await refresh() ?? token
    }

    /// Force a refresh after the server rejected the token (401). Nil when no
    /// refresh token is stored (guest, or signed in before refresh support).
    func refreshAfterRejection() async -> String? {
        await refresh()
    }

    private func refresh() async -> String? {
        if let running = refreshTask { return await running.value }
        guard let refreshToken = Keychain.get(AuthStore.refreshTokenKey),
              !refreshToken.isEmpty else { return nil }
        let task = Task<String?, Never> {
            guard let fresh = try? await GoogleAuth.refreshIdToken(refreshToken: refreshToken) else {
                return nil
            }
            Keychain.set(fresh, for: AuthStore.tokenKey)
            return fresh
        }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    /// True when the JWT's `exp` is within 60s of now (or unreadable).
    private static func isExpiringSoon(_ jwt: String) -> Bool {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3,
              let payload = Data(base64URLEncoded: String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let exp = obj["exp"] as? Double else { return true }
        return Date(timeIntervalSince1970: exp - 60) <= Date()
    }
}
