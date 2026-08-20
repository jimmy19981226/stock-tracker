import SwiftUI

/// Settings, as six plain groups. Every row is either an identity, a
/// preference, or a fact about the system — nothing here is a feature.
struct SettingsView: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.colorScheme) private var colorScheme

    @State private var baseURL = AppConfig.baseURL
    @State private var provider = AISettings.activeProvider
    @State private var apiKey = ""
    @State private var health: String?
    @State private var checking = false
    @State private var quoteSources: QuoteSourcesStatus?
    @State private var deviceMISUp: Bool?
    @State private var showIndices = false
    @State private var showAbout = false
    @ObservedObject private var reports = ReportsStore.shared
    @State private var reportTemplate = "dividend_year"
    @State private var reportPeriod: ReportPeriod = .ytd
    @State private var rendering = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BrandLine()
                Text("Settings")
                    .font(Theme.Typo.title)
                    .foregroundStyle(Theme.text)
                    .padding(.bottom, Theme.Space.l)

                group("Account") { accountCard }
                group("Appearance") { appearanceCard }
                group("AI assistant") { aiCard }
                group("Backend") { backendCard }
                group("Markets & indices") { marketsCard }
                group("Reports") { reportsCard }
                group("About") { aboutCard }

                Text("AI Stock Studio · self-hosted · no analytics, no telemetry\nNot investment advice. Prices may be delayed.")
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Space.xxs)
            }
            .screenPadding(bottom: 20)
        }
        .screenBackground()
        .task { await probe() }
        .onAppear { apiKey = AISettings.apiKey(for: provider) ?? "" }
        .sheet(isPresented: $showIndices) { IndexEditorView().environmentObject(store) }
        .task { await reports.loadCatalog() }
        .fullScreenCover(isPresented: $showAbout) { AboutView { showAbout = false } }
    }

    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.Typo.row)
                .foregroundStyle(Theme.textStrong)
            content()
        }
        .padding(.bottom, Theme.Space.xxl)
    }

    // MARK: Account

    private var accountCard: some View {
        let signedIn = auth.user?.isGuest == false
        return HStack(spacing: Theme.Space.m + 2) {
            Text(auth.user?.initials.isEmpty == false ? auth.user!.initials : "G")
                .font(Theme.Typo.row)
                .foregroundStyle(Theme.accentChipText)
                .frame(width: 38, height: 38)
                .background(Theme.accentTint)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(auth.user.map { $0.email.isEmpty ? $0.name : $0.email } ?? "Guest")
                    .font(Theme.Typo.row)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(signedIn ? "Google sign-in · data scoped to this account"
                              : "Guest · records stay on this backend")
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: Theme.Space.s)

            SecondaryButton(title: signedIn ? "Sign out" : "Sign in") {
                if signedIn { auth.signOut() } else { Task { await auth.signInWithGoogle() } }
            }
        }
        .appCard()
    }

    // MARK: Appearance

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SegmentedControl(options: Appearance.allCases.map { ($0, $0.label) },
                             selection: Binding(get: { settings.appearance },
                                                set: { settings.appearance = $0 }))
            Text(appearanceNote)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.textSecondary)

            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 2)

            Text("Gain / loss colours").statLabelStyle()
            SegmentedControl(options: PLConvention.allCases.map { ($0, $0.label) },
                             selection: Binding(get: { settings.plConvention },
                                                set: { settings.plConvention = $0 }))
            Text("Taiwanese boards paint a rise red. This changes the colours only — never a sign or a number.")
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .appCard()
    }

    private var appearanceNote: String {
        settings.appearance == .system
            ? "Following iOS — currently \(colorScheme == .dark ? "dark" : "light")"
            : "Always \(settings.appearance.label.lowercased())"
    }

    // MARK: AI

    private var aiCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Provider — your own key, stored in the iOS Keychain and sent per request. Never stored on the server.")
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SegmentedControl(options: AIProvider.allCases.map { ($0, $0.shortName) },
                             selection: Binding(get: { provider },
                                                set: { newValue in
                                                    provider = newValue
                                                    AISettings.activeProvider = newValue
                                                    apiKey = AISettings.apiKey(for: newValue) ?? ""
                                                }))

            LabeledField(label: "API key · \(provider.shortName)") {
                SecureField(provider.keyPrefixHint, text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: apiKey) { _, newValue in
                        AISettings.setApiKey(newValue, for: provider)
                    }
            }

            Menu {
                ForEach(provider.availableModels) { model in
                    Button {
                        AISettings.setModel(model.id, for: provider)
                        selectedModel = model.id
                    } label: {
                        Text("\(model.label) — \(model.note)")
                    }
                }
            } label: {
                KeyValueRow("Model") {
                    HStack(spacing: 4) {
                        Text(currentModelLabel)
                            .font(Theme.Typo.detailMed)
                            .foregroundStyle(Theme.accent)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }

            toggleRow("Show reasoning while thinking",
                      isOn: Binding(get: { settings.showReasoning },
                                    set: { settings.showReasoning = $0 }))
            toggleRow("Keep generating in background",
                      isOn: Binding(get: { settings.backgroundGeneration },
                                    set: { settings.backgroundGeneration = $0 }))
        }
        .appCard()
    }

    @State private var selectedModel: String = ""

    private var currentModelLabel: String {
        let id = selectedModel.isEmpty ? AISettings.selectedModel(for: provider) : selectedModel
        return provider.availableModels.first { $0.id == id }?.label ?? id
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1)
            Toggle(isOn: isOn) {
                Text(title)
                    .font(Theme.Typo.detail)
                    .foregroundStyle(Theme.text)
            }
            .tint(Theme.accent)
            .padding(.vertical, 9)
        }
    }

    // MARK: Backend

    private var backendCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            LabeledField(label: "Backend URL") {
                TextField(AppConfig.defaultBaseURL, text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { applyBackend() }
            }
            statusRow("Health", value: health ?? (checking ? "checking…" : "—"),
                      ok: health?.hasPrefix("200") == true)
            statusRow("TW quote relay",
                      value: deviceMISUp == true ? "Connected · TWSE MIS"
                           : quoteSources?.mis.available == true ? "Connected · relay" : "Unavailable",
                      ok: deviceMISUp == true || quoteSources?.mis.available == true)
            statusRow("US quotes",
                      value: quoteSources?.yahoo.available == true ? "Yahoo · reachable" : "Unavailable",
                      ok: quoteSources?.yahoo.available == true)

            SecondaryButton(title: "Apply & reload", fullWidth: true) { applyBackend() }
                .padding(.top, Theme.Space.xxs)
        }
        .appCard()
    }

    private func statusRow(_ key: String, value: String, ok: Bool) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1)
            KeyValueRow(key) {
                HStack(spacing: 5) {
                    Circle().fill(ok ? Theme.gain : Theme.textTertiary).frame(width: 6, height: 6)
                    Text(value)
                        .font(Theme.Typo.detailMed)
                        .foregroundStyle(ok ? Theme.text : Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, Theme.Space.s)
        }
    }

    private func applyBackend() {
        AppConfig.baseURL = baseURL
        toasts.show("Backend set · reloading")
        Task {
            await store.loadMarkets()
            await store.loadAll()
            await probe()
        }
    }

    // MARK: Markets

    private var marketsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(MarketCode.allCases) { market in
                let open = store.isOpen(market)
                KeyValueRow(market.displayName) {
                    HStack(spacing: 5) {
                        Text(store.config(for: market)?.hoursCaption ?? "—")
                            .font(Theme.Typo.detail)
                            .foregroundStyle(Theme.text)
                        Text("·").foregroundStyle(Theme.textTertiary)
                        Text(open ? "Open" : "Closed")
                            .font(Theme.Typo.detailMed)
                            .foregroundStyle(open ? Theme.gain : Theme.textSecondary)
                    }
                }
                .padding(.vertical, 7)
                RowDivider(inset: 0)
            }

            HStack {
                Text("Followed indices · \(store.indices.count)")
                    .font(Theme.Typo.detail)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                SecondaryButton(title: "Edit") { showIndices = true }
            }
            .padding(.top, Theme.Space.m)

            Text("Hours & holidays are DB-driven — editable without a redeploy.")
                .font(Theme.Typo.micro)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, Theme.Space.xs)
        }
        .appCard()
    }

    // MARK: Reports

    /// The layout of a report lives in a Word template on the server, so this
    /// screen picks *which* report and *when* — never how it looks.
    private var reportsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Your records rendered against a Word template on the server. Layout lives in the template, numbers come from your database — change the layout without shipping an app update.")
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: Theme.Space.xs) {
                ForEach(templates) { template in
                    Button { reportTemplate = template.id } label: {
                        templateRow(template, selected: template.id == reportTemplate)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Period").statLabelStyle()
            SegmentedControl(options: ReportPeriod.allCases.map { ($0, $0.label) },
                             selection: $reportPeriod)

            PrimaryButton(title: rendering ? "Rendering with Document Generation…"
                                           : "Export PDF report",
                          disabled: rendering, busy: false) {
                Task { await exportReport() }
            }

            Text("Cached per template and period — the same report is not re-rendered twice."
                 + (reports.renderer == "local"
                    ? " Rendering locally: add ADOBE_CLIENT_ID and a template .docx on the server to use Document Generation."
                    : ""))
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .appCard()
    }

    /// The server's catalogue when it has answered, and the shipped list until
    /// then, so the screen is never empty on first paint.
    private var templates: [ReportTemplate] {
        reports.templates.isEmpty ? Self.fallbackTemplates : reports.templates
    }

    private static let fallbackTemplates: [ReportTemplate] = [
        .init(id: "dividend_year", name: "Dividend year report",
              description: "TW and US payouts split · gross → tax → net", pages: 6),
        .init(id: "holdings_snapshot", name: "Holdings snapshot",
              description: "Positions, cost basis, market value, unrealized P/L", pages: 4),
        .init(id: "realized_pl", name: "Realized P/L & tax summary",
              description: "FIFO-matched sells with holding periods", pages: 5),
        .init(id: "period_performance", name: "Period performance",
              description: "TWR, XIRR and benchmark comparison", pages: 3),
    ]

    private func templateRow(_ template: ReportTemplate, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Circle()
                .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: 1.5)
                .background(Circle().fill(selected ? Theme.accent : .clear).padding(4))
                .frame(width: 15, height: 15)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(template.name)
                    .font(Theme.Typo.row)
                    .foregroundStyle(Theme.text)
                Text(template.description)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            Text("\(template.pages) pp")
                .font(Theme.Typo.microMed)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .background(selected ? Theme.accentTint : .clear)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                .stroke(selected ? Theme.accent : Theme.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
        .contentShape(Rectangle())
    }

    private func exportReport() async {
        rendering = true
        defer { rendering = false }
        guard let job = await reports.generate(template: reportTemplate,
                                               period: reportPeriod.wireValue) else {
            toasts.show("Couldn't start the report")
            return
        }
        // Wait for the job the store is already polling, rather than polling a
        // second time from here.
        for _ in 0..<45 {
            if let current = reports.job(job.reportID), current.status != .pending {
                if current.status == .ready {
                    reports.open(current)
                } else {
                    toasts.show(current.error ?? "Render job failed")
                }
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        toasts.show("The render is taking longer than usual — check back shortly")
    }

    // MARK: About

    private var aboutCard: some View {
        VStack(spacing: 0) {
            KeyValueRow("Version", AppConfig.versionDisplay).padding(.vertical, 5)
            RowDivider(inset: 0)
            KeyValueRow("Market data", "TWSE MIS · Yahoo · FinMind").padding(.vertical, 5)
            RowDivider(inset: 0)
            Button { showAbout = true } label: {
                KeyValueRow("Privacy & disclosures") {
                    Text("View ›")
                        .font(Theme.Typo.detailMed)
                        .foregroundStyle(Theme.accent)
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .appCard()
    }

    // MARK: Probes

    private func probe() async {
        checking = true
        async let sources = try? APIClient.shared.getQuoteSources()
        async let device = MISQuotes.isUp()
        let start = Date()
        let reachable = (try? await APIClient.shared.getMarkets()) != nil
        health = reachable
            ? "200 OK · \(Int(Date().timeIntervalSince(start) * 1000)) ms"
            : "unreachable"
        quoteSources = await sources
        deviceMISUp = await device
        checking = false
    }
}

/// The disclosures page. Long-form, so it gets a full screen rather than a
/// sheet the user has to scroll inside a scroll.
struct AboutView: View {
    let onClose: () -> Void

    var body: some View {
        ModalScaffold(title: "Privacy & disclosures", onClose: onClose) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                paragraph("Your trades and dividends live in your own database — SQLite on disk or your own Postgres. Nothing is sent to us, and there is no analytics or telemetry in this app.")
                paragraph("Market data comes from public endpoints only: TWSE MIS for Taiwan quotes, Yahoo for US quotes and daily history, FinMind for Taiwan monthly revenue. No broker login is ever required.")
                paragraph("The assistant is opt-in. When you ask a question, your portfolio snapshot is sent to the provider you chose, using your own API key. The key is stored in the iOS Keychain and never on the server.")
                Text("This app reports your own records and public data. It does not provide investment advice or recommendations, and prices may be delayed.")
                    .font(Theme.Typo.bodyMed)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Version \(AppConfig.versionDisplay)")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.body)
            .foregroundStyle(Theme.text)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }
}
