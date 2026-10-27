import Foundation

/// One Gemini model for the iOS assistant. Older provider/model preferences
/// are intentionally ignored; the existing Gemini Keychain entry is retained.
enum AISettings {
    static let providerName = "Gemini"
    static let modelID = "gemini-3.5-flash-lite"
    static let modelLabel = "Gemini 3.5 Flash-Lite"
    static let apiKeyURL = URL(string: "https://aistudio.google.com/apikey")!

    private static let keychainKey = "ai.key.gemini"
    static let connectionPreferenceKey = "ai.usePersonalGeminiKey"

    static var usePersonalKey: Bool {
        get { UserDefaults.standard.object(forKey: connectionPreferenceKey) as? Bool ?? hasKey }
        set { UserDefaults.standard.set(newValue, forKey: connectionPreferenceKey) }
    }

    static var apiKey: String? { Keychain.get(keychainKey) }

    static var hasKey: Bool {
        !(apiKey ?? "").isEmpty
    }

    static func setApiKey(_ key: String?) {
        Keychain.set(key?.trimmingCharacters(in: .whitespacesAndNewlines), for: keychainKey)
    }

    static func configure(_ request: inout URLRequest) {
        configure(&request, usePersonalKey: usePersonalKey, apiKey: apiKey)
    }

    static func configure(_ request: inout URLRequest, usePersonalKey: Bool, apiKey: String?) {
        request.setValue("gemini", forHTTPHeaderField: "X-AI-Provider")
        request.setValue(modelID, forHTTPHeaderField: "X-AI-Model")
        // Setting nil also removes a key on a reused request.
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue(usePersonalKey ? trimmedKey.flatMap { $0.isEmpty ? nil : $0 } : nil,
                         forHTTPHeaderField: "X-AI-Key")
    }
}
