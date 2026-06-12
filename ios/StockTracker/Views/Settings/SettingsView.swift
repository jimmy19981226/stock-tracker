import SwiftUI

/// Lets the user point the app at a different backend (e.g. the Mac's LAN IP
/// when running on a physical device, or the deployed Render URL).
struct SettingsView: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = AppConfig.baseURL
    @State private var googleClientID = AppConfig.googleClientID
    @State private var checking = false
    @State private var checkResult: String?
    @AppStorage("ui.style") private var styleRaw = AppStyle.emerald.rawValue
    @State private var quoteSources: QuoteSourcesStatus?
    @State private var deviceMISUp: Bool?
    @State private var loadingSources = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    HStack(spacing: 12) {
                        Image(systemName: auth.user?.isGuest == false ? "person.crop.circle.fill" : "person.crop.circle")
                            .font(.system(size: 32))
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(auth.user?.name ?? "Guest")
                                .font(.headline)
                            if let email = auth.user?.email, !email.isEmpty {
                                Text(email).font(.caption).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                    Button(auth.user?.isGuest == false ? "Sign out" : "Sign in with Google") {
                        if auth.user?.isGuest == false { auth.signOut() }
                        else { Task { await auth.signInWithGoogle() } }
                        dismiss()
                    }
                    .foregroundStyle(auth.user?.isGuest == false ? Theme.negative : Theme.accent)
                }

                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(AppStyle.allCases) { style in
                                VStack(spacing: 7) {
                                    ZStack {
                                        Circle()
                                            .fill(style.accent)
                                            .frame(width: 44, height: 44)
                                        if styleRaw == style.rawValue {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 16, weight: .heavy))
                                                .foregroundStyle(.black)
                                        }
                                    }
                                    Text(style.displayName)
                                        .font(.caption2.weight(
                                            styleRaw == style.rawValue ? .bold : .regular))
                                        .foregroundStyle(styleRaw == style.rawValue
                                                         ? Theme.primaryText : Theme.secondaryText)
                                }
                                .onTapGesture { styleRaw = style.rawValue }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Changes the accent color across the app. Gains stay green and losses red regardless of style.")
                }

                Section {
                    NavigationLink {
                        AIProviderSettingsView()
                    } label: {
                        HStack {
                            Label("AI Assistant", systemImage: "sparkles")
                            Spacer()
                            Text(AISettings.activeProvider.displayName)
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                } header: {
                    Text("AI")
                } footer: {
                    Text("Choose OpenAI, Gemini or Claude and use your own API key.")
                }

                Section {
                    sourceRow(name: "TWSE MIS", caption: "Real-time",
                              info: deviceMISUp.map { QuoteSourceInfo(available: $0, via: nil, realtime: true) })
                    sourceRow(name: "Yahoo Finance", caption: "Delayed ~15 min", info: quoteSources?.yahoo)
                } header: {
                    Text("Market Data")
                } footer: {
                    Text("TWSE MIS real-time quotes are used whenever they're reachable; Yahoo covers US stocks and fills in whenever MIS can't answer.")
                }

                Section {
                    TextField("123-abc.apps.googleusercontent.com", text: $googleClientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Google OAuth Client ID")
                } footer: {
                    Text("Required for Google sign-in. Create an iOS OAuth client in Google Cloud Console for bundle id com.aistockstudio.app.")
                }

                Section {
                    TextField("http://127.0.0.1:8011", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Backend URL")
                } footer: {
                    Text("Simulator can use 127.0.0.1. On a real iPhone, use your Mac's LAN IP, e.g. http://192.168.1.20:8011, and start uvicorn with --host 0.0.0.0.")
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            Spacer()
                            if checking { ProgressView() }
                            else if let r = checkResult {
                                Text(r).foregroundStyle(r == "OK" ? Theme.positive : Theme.negative)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .task { await loadQuoteSources() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        AppConfig.baseURL = baseURL
                        AppConfig.googleClientID = googleClientID
                        Task {
                            await store.loadMarkets()
                            await store.loadAll()
                        }
                        dismiss()
                    }
                }
            }
        }
    }

    /// One availability row: green/red dot, source name, freshness caption,
    /// and the probe verdict on the right (spinner while probing).
    private func sourceRow(name: String, caption: String, info: QuoteSourceInfo?) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(info == nil ? Theme.mutedText
                      : info!.available ? Theme.positive : Theme.negative)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if loadingSources {
                ProgressView()
            } else if let info {
                Text(info.available
                     ? (info.via == "relay" ? "Available · relay"
                        : info.via == "direct" ? "Available · direct" : "Available")
                     : "Unavailable")
                    .font(.caption)
                    .foregroundStyle(info.available ? Theme.positive : Theme.negative)
            }
        }
    }

    private func loadQuoteSources() async {
        loadingSources = true
        async let backend = try? APIClient.shared.getQuoteSources()
        async let device = MISProbe.isUp()
        quoteSources = await backend
        deviceMISUp = await device
        loadingSources = false
    }

    private func testConnection() async {
        checking = true
        checkResult = nil
        let saved = AppConfig.baseURL
        AppConfig.baseURL = baseURL
        do {
            _ = try await APIClient.shared.getMarkets()
            checkResult = "OK"
        } catch {
            checkResult = "Failed"
        }
        AppConfig.baseURL = saved
        checking = false
    }
}
