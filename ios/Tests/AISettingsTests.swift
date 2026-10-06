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
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-AI-Key"), AISettings.apiKey)
        }
    }
}
