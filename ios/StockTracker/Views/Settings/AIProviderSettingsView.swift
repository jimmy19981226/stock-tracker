import SwiftUI

/// Choose which LLM powers the Assistant, paste your own API key for each,
/// and pick which model to use. Keys live in the Keychain; model choice and
/// active provider are stored in UserDefaults. Everything is sent to the
/// backend per request — nothing is persisted server-side.
struct AIProviderSettingsView: View {
    @State private var active = AISettings.activeProvider
    @State private var keys: [AIProvider: String] = [:]
    @State private var selectedModels: [AIProvider: String] = [:]

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
                Text("The Assistant uses this provider and model with the key you enter below.")
            }

            ForEach(AIProvider.allCases) { provider in
                Section {
                    SecureField(provider.keyPrefixHint, text: keyBinding(for: provider))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: keys[provider] ?? "") { _, newValue in
                            AISettings.setApiKey(newValue, for: provider)
                        }

                    Picker("Model", selection: modelBinding(for: provider)) {
                        ForEach(provider.availableModels) { m in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.label)
                                Text(m.note)
                                    .font(.caption)
                                    .foregroundStyle(Theme.mutedText)
                            }
                            .tag(m.id)
                        }
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
                    let modelId = selectedModels[provider] ?? provider.defaultModel
                    Text("Key: \(provider.keyHint)  ·  Model: \(modelId)")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("AI Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            for p in AIProvider.allCases {
                keys[p] = AISettings.apiKey(for: p) ?? ""
                selectedModels[p] = AISettings.selectedModel(for: p)
            }
        }
    }

    private func keyBinding(for provider: AIProvider) -> Binding<String> {
        Binding(
            get: { keys[provider] ?? "" },
            set: { keys[provider] = $0 }
        )
    }

    private func modelBinding(for provider: AIProvider) -> Binding<String> {
        Binding(
            get: { selectedModels[provider] ?? provider.defaultModel },
            set: { newModel in
                selectedModels[provider] = newModel
                AISettings.setModel(newModel, for: provider)
            }
        )
    }
}
