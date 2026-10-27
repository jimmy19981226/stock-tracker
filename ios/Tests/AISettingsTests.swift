import XCTest
@testable import StockTracker

final class AISettingsTests: XCTestCase {
    func testLegacyProviderAndModelPreferencesCannotOverrideChatRequests() {
        let defaults = UserDefaults.standard
        let keys = ["ai.activeProvider", "ai.model.gemini"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        defaults.set("gemini-2.5-pro", forKey: "ai.model.gemini")
        for provider in ["openai", "claude", "nvidia"] {
            defaults.set(provider, forKey: "ai.activeProvider")
            var request = URLRequest(url: URL(string: "https://example.invalid/api/ai/chat")!)
            request.setValue(provider, forHTTPHeaderField: "X-AI-Provider")
            request.setValue("old-model", forHTTPHeaderField: "X-AI-Model")

            AISettings.configure(&request)

            XCTAssertEqual(request.value(forHTTPHeaderField: "X-AI-Provider"), "gemini")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-AI-Model"), "gemini-3.5-flash-lite")
            let configuredKey = AISettings.usePersonalKey ? AISettings.apiKey : nil
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-AI-Key"), configuredKey)
        }
    }

    func testIncludedAIUsesServerCredentialsEvenWhenAPersonalKeyExists() {
        var request = URLRequest(url: URL(string: "https://example.invalid/api/ai/chat")!)
        request.setValue("stale-personal-test-key", forHTTPHeaderField: "X-AI-Key")
        AISettings.configure(&request, usePersonalKey: false, apiKey: "stored-personal-test-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-AI-Key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AI-Provider"), "gemini")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AI-Model"), AISettings.modelID)
    }

    func testPersonalKeyModeSendsOnlyTheTrimmedExplicitKey() {
        var request = URLRequest(url: URL(string: "https://example.invalid/api/ai/chat")!)
        AISettings.configure(&request, usePersonalKey: true, apiKey: " \n personal-test-key \t")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AI-Key"), "personal-test-key")
        AISettings.configure(&request, usePersonalKey: false, apiKey: "personal-test-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-AI-Key"), "Switching to Included AI must remove a reused header")
    }

    func testEmptyPersonalKeyNeverSendsAnEmptyOrStaleHeader() {
        for key in [nil, "", " \n\t "] as [String?] {
            var request = URLRequest(url: URL(string: "https://example.invalid/api/ai/chat")!)
            request.setValue("stale-test-key", forHTTPHeaderField: "X-AI-Key")
            AISettings.configure(&request, usePersonalKey: true, apiKey: key)
            XCTAssertNil(request.value(forHTTPHeaderField: "X-AI-Key"))
        }
    }

    func testExplicitIncludedPreferenceOverridesLegacyKeyPresenceWithoutChangingKeychain() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AISettings.connectionPreferenceKey)
        defer {
            if let previous { defaults.set(previous, forKey: AISettings.connectionPreferenceKey) }
            else { defaults.removeObject(forKey: AISettings.connectionPreferenceKey) }
        }
        AISettings.usePersonalKey = false
        var request = URLRequest(url: URL(string: "https://example.invalid/api/ai/chat")!)
        request.setValue("legacy-test-key", forHTTPHeaderField: "X-AI-Key")
        AISettings.configure(&request)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-AI-Key"))
        XCTAssertFalse(AISettings.usePersonalKey)
    }
}
