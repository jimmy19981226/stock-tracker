import Foundation

/// Which LLM powers the Assistant, and the user's own API key for it. Keys are
/// stored in the Keychain (one per provider) and sent to the backend per request
/// — never persisted server-side. The active provider is a plain UserDefaults pref.
enum AIProvider: String, CaseIterable, Identifiable {
    case gemini
    case openai
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .openai: return "OpenAI"
        case .claude: return "Anthropic Claude"
        }
    }

    /// Where to get a key, shown under the field.
    var keyHint: String {
        switch self {
        case .gemini: return "aistudio.google.com/apikey"
        case .openai: return "platform.openai.com/api-keys"
        case .claude: return "console.anthropic.com"
        }
    }

    var keyPrefixHint: String {
        switch self {
        case .gemini: return "AIza…"
        case .openai: return "sk-…"
        case .claude: return "sk-ant-…"
        }
    }

    fileprivate var keychainKey: String { "ai.key.\(rawValue)" }
}

enum AISettings {
    private static let providerKey = "ai.activeProvider"

    static var activeProvider: AIProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: providerKey) ?? AIProvider.gemini.rawValue
            return AIProvider(rawValue: raw) ?? .gemini
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }

    static func apiKey(for provider: AIProvider) -> String? {
        Keychain.get(provider.keychainKey)
    }

    static func setApiKey(_ key: String?, for provider: AIProvider) {
        Keychain.set(key?.trimmingCharacters(in: .whitespacesAndNewlines), for: provider.keychainKey)
    }

    static func hasKey(for provider: AIProvider) -> Bool {
        !(apiKey(for: provider) ?? "").isEmpty
    }
}
