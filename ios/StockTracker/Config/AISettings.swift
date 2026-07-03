import Foundation

/// Which LLM powers the Assistant, and the user's own API key for it. Keys are
/// stored in the Keychain (one per provider) and sent to the backend per request
/// — never persisted server-side. The active provider and selected model are
/// plain UserDefaults prefs.
enum AIProvider: String, CaseIterable, Identifiable {
    case gemini
    case openai
    case claude
    case nvidia

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .openai: return "OpenAI"
        case .claude: return "Anthropic Claude"
        case .nvidia: return "NVIDIA NIM"
        }
    }

    /// Where to get a key, shown under the field.
    var keyHint: String {
        switch self {
        case .gemini: return "aistudio.google.com/apikey"
        case .openai: return "platform.openai.com/api-keys"
        case .claude: return "console.anthropic.com"
        case .nvidia: return "build.nvidia.com (free)"
        }
    }

    var keyPrefixHint: String {
        switch self {
        case .gemini: return "AIza…"
        case .openai: return "sk-…"
        case .claude: return "sk-ant-…"
        case .nvidia: return "nvapi-…"
        }
    }

    /// Supported models for this provider, in display order.
    var availableModels: [AIModel] {
        switch self {
        case .gemini:
            return [
                AIModel(id: "gemini-2.5-flash", label: "Gemini 2.5 Flash", note: "Fast · recommended"),
                AIModel(id: "gemini-2.5-pro",   label: "Gemini 2.5 Pro",   note: "More capable"),
            ]
        case .openai:
            return [
                AIModel(id: "gpt-4o",      label: "GPT-4o",      note: "Best all-around · recommended"),
                AIModel(id: "gpt-4o-mini", label: "GPT-4o mini", note: "Fast & cheap"),
                AIModel(id: "o3",          label: "o3",           note: "Deep reasoning · slower"),
            ]
        case .claude:
            return [
                AIModel(id: "claude-opus-4-8",          label: "Claude Opus 4.8",   note: "Most capable · recommended"),
                AIModel(id: "claude-sonnet-4-6",        label: "Claude Sonnet 4.6", note: "Balanced speed & quality"),
                AIModel(id: "claude-haiku-4-5-20251001",label: "Claude Haiku 4.5",  note: "Fast & cheap"),
            ]
        case .nvidia:
            return [
                AIModel(id: "deepseek-ai/deepseek-v4-pro", label: "DeepSeek V4 Pro", note: "Free · smartest, strong Chinese · recommended"),
                AIModel(id: "moonshotai/kimi-k2.6",        label: "Kimi K2.6",       note: "Free · superb instruction following"),
                AIModel(id: "z-ai/glm-5.2",                label: "GLM-5.2",         note: "Free · strong Chinese & reasoning"),
            ]
        }
    }

    var defaultModel: String { availableModels[0].id }

    fileprivate var keychainKey: String { "ai.key.\(rawValue)" }
    fileprivate var modelKey: String { "ai.model.\(rawValue)" }
}

struct AIModel: Identifiable, Equatable {
    let id: String
    let label: String
    let note: String
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

    static func selectedModel(for provider: AIProvider) -> String {
        UserDefaults.standard.string(forKey: provider.modelKey) ?? provider.defaultModel
    }

    static func setModel(_ model: String, for provider: AIProvider) {
        UserDefaults.standard.set(model, forKey: provider.modelKey)
    }
}
