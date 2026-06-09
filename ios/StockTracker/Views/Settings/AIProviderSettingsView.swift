import SwiftUI

/// Choose which LLM powers the Assistant and paste your own API key for each.
/// Keys live in the Keychain and are sent to the backend per request.
struct AIProviderSettingsView: View {
    @State private var active = AISettings.activeProvider
    @State private var keys: [AIProvider: String] = [:]

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $active) {
                    ForEach(AIProvider.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .onChange(of: active) { _, newValue in
                    AISettings.activeProvider = newValue
                }
            } header: {
                Text("Active AI")
            } footer: {
                Text("The Assistant uses this provider with the key you enter below.")
            }

            ForEach(AIProvider.allCases) { provider in
                Section {
                    SecureField(provider.keyPrefixHint, text: binding(for: provider))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: keys[provider] ?? "") { _, newValue in
                            AISettings.setApiKey(newValue, for: provider)
                        }
                } header: {
                    HStack {
                        Text(provider.displayName)
                        if provider == active {
                            Text("ACTIVE")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(Theme.accent)
                        }
                        Spacer()
                        if AISettings.hasKey(for: provider) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.positive)
                        }
                    }
                } footer: {
                    Text("Get a key at \(provider.keyHint)")
                }
            }
        }
        .navigationTitle("AI Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            for p in AIProvider.allCases { keys[p] = AISettings.apiKey(for: p) ?? "" }
        }
    }

    private func binding(for provider: AIProvider) -> Binding<String> {
        Binding(
            get: { keys[provider] ?? "" },
            set: { keys[provider] = $0 }
        )
    }
}
