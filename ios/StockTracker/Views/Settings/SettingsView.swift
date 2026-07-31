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
    @State private var quoteSources: QuoteSourcesStatus?
    @State private var deviceMISUp: Bool?
    @State private var loadingSources = false

    /// Developer plumbing stays folded away by default. A backend URL and an
    /// OAuth client id are things you set once, if ever — giving them the same
    /// prominence as your account made the screen read as a config file.
    @State private var showAdvanced = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    accountCard
                    aiCard
                    marketDataCard
                    advancedCard

                    // Version lives here as well as on the splash — Settings is
                    // where people actually go looking for it, and both read the
                    // same bundle values so they can't disagree.
                    Text("AI Stock Studio · Version \(AppConfig.versionDisplay)")
                        .font(Theme.Typo.micro)
                        .foregroundStyle(Theme.mutedText)
                        .padding(.top, Theme.Space.xs)
                }
                .padding(16)
                .padding(.bottom, 40)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .task { await loadQuoteSources() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // An icon (circular glass control), not text ("Cancel" renders
                // as a rounded rectangle that visibly morphs into the circular
                // back chevron when a subpage like AI Assistant is pushed).
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel")
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

    // MARK: - Cards

    /// Identity leads the screen: who you're signed in as, and the one action
    /// that changes it.
    private var accountCard: some View {
        let signedIn = auth.user?.isGuest == false
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: signedIn ? "person.crop.circle.fill" : "person.crop.circle")
                        .font(.system(size: 34))
                        .foregroundStyle(signedIn ? Theme.accent : Theme.mutedText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(auth.user?.name ?? "Guest")
                            .font(Theme.Typo.section)
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)
                        Text(auth.user.map { $0.email.isEmpty ? "Not signed in" : $0.email }
                             ?? "Not signed in")
                            .font(Theme.Typo.caption)
                            .foregroundStyle(Theme.mutedText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    if signedIn { auth.signOut() }
                    else { Task { await auth.signInWithGoogle() } }
                    dismiss()
                } label: {
                    Text(signedIn ? "Sign out" : "Sign in with Google")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(signedIn ? Theme.negative : Color.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(signedIn ? Theme.wash(Theme.negative) : Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var aiCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                settingsLabel("ASSISTANT")
                NavigationLink { AIProviderSettingsView() } label: {
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 30, height: 30)
                            .background(Theme.wash(Theme.accent))
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("AI provider")
                                .font(Theme.Typo.value)
                                .foregroundStyle(Theme.primaryText)
                            Text("OpenAI, Gemini or Claude — with your own key")
                                .font(Theme.Typo.micro)
                                .foregroundStyle(Theme.mutedText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        Spacer(minLength: Theme.Space.s)
                        Text(AISettings.activeProvider.displayName)
                            .font(Theme.Typo.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.mutedText)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var marketDataCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                settingsLabel("MARKET DATA")
                sourceRow(name: "TWSE MIS",
                          covers: "Real-time · Taiwan stocks",
                          info: deviceMISUp.map { QuoteSourceInfo(available: $0, via: nil, realtime: true) })
                sourceRow(name: "Yahoo Finance",
                          covers: "Delayed · US stocks + TW fallback",
                          info: quoteSources?.yahoo)
                Text("MIS serves real-time Taiwan quotes when reachable. Yahoo covers US at all times and fills in for Taiwan when MIS is unavailable.")
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Backend URL, OAuth client id and the connection test — folded away.
    private var advancedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Button {
                    withAnimation(.snappy(duration: 0.28)) { showAdvanced.toggle() }
                } label: {
                    HStack {
                        settingsLabel("ADVANCED")
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.mutedText)
                            .rotationEffect(.degrees(showAdvanced ? 0 : -90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showAdvanced {
                    field("Backend URL", text: $baseURL,
                          placeholder: "http://127.0.0.1:8011", url: true,
                          hint: "Simulator can use 127.0.0.1. On a real iPhone use your Mac's LAN IP and start uvicorn with --host 0.0.0.0.")
                    field("Google OAuth client ID", text: $googleClientID,
                          placeholder: "123-abc.apps.googleusercontent.com", url: false,
                          hint: "Required for Google sign-in. Create an iOS OAuth client for bundle id com.aistockstudio.app.")
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack(spacing: Theme.Space.s) {
                            Text("Test connection")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.accent)
                            Spacer()
                            if checking {
                                ProgressView().controlSize(.small)
                            } else if let r = checkResult {
                                Text(r)
                                    .font(Theme.Typo.caption)
                                    .foregroundStyle(r == "OK" ? Theme.positive : Theme.negative)
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, Theme.Space.m)
                        .background(Theme.cardElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func settingsLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.label)
            .tracking(0.8)
            .foregroundStyle(Theme.mutedText)
    }

    private func field(_ title: String, text: Binding<String>,
                       placeholder: String, url: Bool, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.secondaryText)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(url ? .URL : .default)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
                .padding(.vertical, 10)
                .padding(.horizontal, Theme.Space.m)
                .background(Theme.cardElevated)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            Text(hint)
                .font(Theme.Typo.micro)
                .foregroundStyle(Theme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One market-data source row: status dot, name + what it covers, and
    /// live probe verdict on the right — "In use" when active, "Unavailable" when not.
    private func sourceRow(name: String, covers: String, info: QuoteSourceInfo?) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(info == nil ? Theme.mutedText
                      : info!.available ? Theme.positive : Theme.negative)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(covers)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if loadingSources {
                ProgressView()
            } else if let info {
                let viaSuffix = info.via.map { " · \($0)" } ?? ""
                Text(info.available ? "In use\(viaSuffix)" : "Unavailable")
                    .font(.caption.weight(info.available ? .medium : .regular))
                    .foregroundStyle(info.available ? Theme.positive : Theme.negative)
            }
        }
    }

    private func loadQuoteSources() async {
        loadingSources = true
        async let backend = try? APIClient.shared.getQuoteSources()
        async let device = MISQuotes.isUp()
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
