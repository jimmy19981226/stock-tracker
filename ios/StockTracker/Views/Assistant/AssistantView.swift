import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class AssistantViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var streamingText = ""
    @Published var isStreaming = false
    /// Backend progress before the first answer token ("Searching the web…").
    @Published var streamStatus: String?
    /// Streamed reasoning (Claude extended thinking / Gemini thought
    /// summaries) — rendered in a collapsible section above the reply.
    @Published var thinkingText = ""
    @Published var input = ""
    @Published var status: AiStatus?
    @Published var error: String?

    // Image-import flow inside the chat: attach → parse → review card → add.
    @Published var importImage: UIImage?
    @Published var isParsingImport = false
    @Published var pendingImport: ParsedRecords?
    @Published var importTradeOn: [Bool] = []
    @Published var importDividendOn: [Bool] = []
    @Published var isSubmittingImport = false

    private var chatId: Int?
    /// The in-flight streaming task, so a reset / teardown can cancel it and
    /// stop late onChunk/onDone callbacks from mutating a fresh transcript.
    private var streamTask: Task<Void, Never>?
    /// Polls for a reply the server finished while our stream was dead
    /// (app backgrounded, network blip) — generation continues server-side.
    private var recoverTask: Task<Void, Never>?
    /// Extra execution window so a reply keeps streaming ~30s after the user
    /// switches apps or locks the screen.
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    init() {
        // UI-test hook: seed a markdown-table reply to screenshot the renderer.
        if ProcessInfo.processInfo.environment["UITEST_CHAT_TABLE"] == "1" {
            messages = [
                ChatMessage(role: "user", content: "How are my TW holdings doing?"),
                ChatMessage(role: "assistant", content: """
                **Your TW Holdings Snapshot (NT$)**

                | Metric | Value |
                |---|---|
                | Total market value | **NT$1,754,047** |
                | Total cost | NT$1,485,309 |
                | Unrealized P/L | **+NT$261,002** (+17.6%) |
                | Today's P/L | NT$0 (market closed) |

                Solid unrealized gain — 2330 (台積電) is doing the heavy lifting.
                """),
            ]
        }
        // UI-test hook: seed a parsed-import review card to screenshot the flow.
        if ProcessInfo.processInfo.environment["UITEST_CHAT_IMPORT"] == "1" {
            messages = [ChatMessage(role: "user", content: "(attached a brokerage screenshot)")]
            pendingImport = ParsedRecords(
                trades: [
                    ParsedTradeRow(type: .buy, ticker: "2330", shares: 100, price: 1050,
                                   date: "2024-11-05", fee: 50, notes: nil),
                    ParsedTradeRow(type: .sell, ticker: "2317", shares: 500, price: 210.5,
                                   date: "2024-11-20", fee: 45, notes: nil),
                ],
                dividends: [
                    ParsedDividendRow(ticker: "0050", amount: 3200, date: "2024-12-10", notes: nil),
                ],
                notes: ""
            )
            importTradeOn = [true, true]
            importDividendOn = [true]
        }
        // UI-test hook: seed a sample formatted reply to screenshot the renderer.
        if ProcessInfo.processInfo.environment["UITEST_ASSISTANT_DEMO"] == "1" {
            messages = [
                ChatMessage(role: "user", content: "How is my Taiwan portfolio doing?"),
                ChatMessage(role: "assistant", content: """
                <!--meta:{"queries":[]}-->
                ## Taiwan portfolio snapshot

                Your **TW** book is up **+1.83%** today and **+NT$286,657** overall. A few highlights:

                - **2330 台積電** — your largest position, **+282%** unrealized
                - **3034 聯詠** — steady contributor
                - Dividends received this year: **NT$4,000**

                ### What stands out
                1. Concentration in semiconductors is high
                2. Realized P&L is modest vs. unrealized gains

                > Tip: review position sizing if 2330 exceeds your target weight.

                Inline code like `2330.TW` and a block:

                ```
                weight = position_value / total_value
                ```

                **Sources:**
                1. [https://vertexaisearch.cloud.google.com/grounding-api-redirect/AbCdEfGhIjKlMnOpQrStUvWxYz1234567890](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AbCdEfGhIjKlMnOpQrStUvWxYz1234567890)
                2. [cnbc.com](https://www.cnbc.com/quotes/2330-TW)
                """),
            ]
        }
    }

    func loadStatus() async {
        status = try? await APIClient.shared.getAiStatus()
    }

    var canSend: Bool {
        !input.trimmingCharacters(in: .whitespaces).isEmpty && !isStreaming
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isStreaming else { return }
        input = ""
        error = nil
        recoverTask?.cancel()
        messages.append(ChatMessage(role: "user", content: text))
        isStreaming = true
        streamingText = ""
        thinkingText = ""
        beginBackgroundTask()
        // Server truth after this turn completes: everything local so far
        // plus the assistant reply — used by recovery to know it landed.
        let expectedCount = messages.count + 1

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await APIClient.shared.streamChat(
                    chatId: chatId,
                    message: text,
                    onInit: { [weak self] id, _ in
                        guard let self, !Task.isCancelled else { return }
                        self.chatId = id
                    },
                    onChunk: { [weak self] delta in
                        guard let self, !Task.isCancelled else { return }
                        self.streamStatus = nil
                        self.streamingText += delta
                    },
                    onDone: { [weak self] content, _ in
                        guard let self, !Task.isCancelled else { return }
                        let final = content.isEmpty ? self.streamingText : content
                        self.messages.append(ChatMessage(role: "assistant", content: final))
                        self.streamingText = ""
                        self.streamStatus = nil
                    },
                    onStatus: { [weak self] text in
                        guard let self, !Task.isCancelled else { return }
                        self.streamStatus = text
                    },
                    onAction: { [weak self] records in
                        guard let self, !Task.isCancelled else { return }
                        // A write tool proposed records — show the same
                        // confirm card the image import uses. Nothing is
                        // saved until the user taps Add.
                        self.pendingImport = records
                        self.importTradeOn = Array(repeating: true, count: records.trades.count)
                        self.importDividendOn = Array(repeating: true, count: records.dividends.count)
                    },
                    onThinking: { [weak self] delta in
                        guard let self, !Task.isCancelled else { return }
                        self.streamStatus = nil
                        self.thinkingText += delta
                    }
                )
            } catch {
                // A cancelled stream is an intentional teardown, not an error.
                if !Task.isCancelled {
                    self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
                    if !self.streamingText.isEmpty {
                        self.messages.append(ChatMessage(role: "assistant", content: self.streamingText))
                        self.streamingText = ""
                    }
                    // The server keeps generating even though our stream died
                    // (e.g. the app was backgrounded past the grace window) —
                    // poll until the finished reply lands, then swap it in.
                    self.startRecovery(expectedCount: expectedCount)
                }
            }
            if !Task.isCancelled { self.isStreaming = false }
            self.endBackgroundTask()
        }
    }

    /// Stop generation mid-stream, keeping whatever has arrived as the reply.
    /// Also cancels the server-side run so it stops burning tokens.
    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        recoverTask?.cancel()
        if let id = chatId {
            Task { try? await APIClient.shared.stopChat(id) }
        }
        if !streamingText.isEmpty {
            messages.append(ChatMessage(role: "assistant", content: streamingText))
        }
        streamingText = ""
        streamStatus = nil
        isStreaming = false
        endBackgroundTask()
    }

    func reset() {
        streamTask?.cancel()
        streamTask = nil
        recoverTask?.cancel()
        chatId = nil
        messages = []
        streamingText = ""
        streamStatus = nil
        thinkingText = ""
        isStreaming = false
        error = nil
        endBackgroundTask()
        cancelImport()
    }

    deinit {
        streamTask?.cancel()
        recoverTask?.cancel()
    }

    // MARK: - Background continuation

    private func beginBackgroundTask() {
        endBackgroundTask()
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "ai-generation") {
            [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }
    }

    /// Fetch the chat until the server-persisted reply appears (generation
    /// finishes server-side even with no client attached), then replace the
    /// local transcript with the canonical one.
    private func startRecovery(expectedCount: Int) {
        guard let id = chatId else { return }
        recoverTask?.cancel()
        recoverTask = Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if let detail = try? await APIClient.shared.getChat(id),
                   detail.messages.count >= expectedCount,
                   detail.messages.last?.role == "assistant" {
                    self.messages = detail.messages
                    self.streamingText = ""
                    self.streamStatus = nil
                    self.error = nil
                    self.isStreaming = false
                    return
                }
            }
        }
    }

    // MARK: - Image import (in-chat)

    func handlePickedImage(_ rawData: Data) async {
        error = nil
        var data = rawData
        // Downscale large photos so the upload stays small.
        if let img = UIImage(data: data) {
            let maxDim: CGFloat = 2200
            let scale = min(1, maxDim / max(img.size.width, img.size.height))
            let target = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: target)
            let resized = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: target)) }
            importImage = resized
            data = resized.jpegData(compressionQuality: 0.8) ?? data
        }
        isParsingImport = true
        pendingImport = nil
        do {
            let result = try await APIClient.shared.parseRecords(imageData: data)
            pendingImport = result
            importTradeOn = Array(repeating: true, count: result.trades.count)
            importDividendOn = Array(repeating: true, count: result.dividends.count)
            if result.trades.isEmpty && result.dividends.isEmpty {
                let note = result.notes.isEmpty
                    ? "I couldn't find any trades or dividends in that image. Try a clearer screenshot."
                    : result.notes
                messages.append(ChatMessage(role: "assistant", content: note))
                cancelImport()
            }
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            cancelImport()
        }
        isParsingImport = false
    }

    func submitImport(store: PortfolioStore) async {
        guard let parsed = pendingImport else { return }
        isSubmittingImport = true
        var added = (trades: 0, dividends: 0)
        var failures = 0
        for (i, row) in parsed.trades.enumerated()
        where importTradeOn.indices.contains(i) && importTradeOn[i] {
            let payload = TradeCreate(
                type: row.type, ticker: row.ticker, shares: row.shares,
                price: row.price, tradeDate: row.date, fee: row.fee ?? 0,
                notes: row.notes, market: nil)
            do { _ = try await APIClient.shared.createTrade(payload); added.trades += 1 }
            catch { failures += 1 }
        }
        for (i, row) in parsed.dividends.enumerated()
        where importDividendOn.indices.contains(i) && importDividendOn[i] {
            let payload = DividendCreate(
                ticker: row.ticker, amount: row.amount,
                payDate: row.date, notes: row.notes, market: nil)
            do { _ = try await APIClient.shared.createDividend(payload); added.dividends += 1 }
            catch { failures += 1 }
        }
        await store.loadAll()

        var summary = "✅ Added"
        var parts: [String] = []
        if added.trades > 0 { parts.append(" \(added.trades) trade\(added.trades == 1 ? "" : "s")") }
        if added.dividends > 0 { parts.append(" \(added.dividends) dividend\(added.dividends == 1 ? "" : "s")") }
        summary += parts.isEmpty ? " nothing" : parts.joined(separator: " and")
        summary += " to your portfolio."
        if failures > 0 { summary += " ⚠️ \(failures) row\(failures == 1 ? "" : "s") failed." }
        messages.append(ChatMessage(role: "assistant", content: summary))

        isSubmittingImport = false
        cancelImport()
    }

    func cancelImport() {
        importImage = nil
        pendingImport = nil
        importTradeOn = []
        importDividendOn = []
        isParsingImport = false
        isSubmittingImport = false
    }

    var currentChatId: Int? { chatId }

    // MARK: - Chat history

    @Published var chats: [ChatSummary] = []
    @Published var loadingChats = false

    func loadChats() async {
        loadingChats = true
        chats = (try? await APIClient.shared.listChats()) ?? []
        loadingChats = false
    }

    /// Open a past conversation into the transcript.
    func openChat(_ id: Int) async {
        guard let detail = try? await APIClient.shared.getChat(id) else { return }
        messages = detail.messages
        streamingText = ""
        thinkingText = ""
        error = nil
        chatId = detail.id
    }

    func deleteChat(_ id: Int) async {
        try? await APIClient.shared.deleteChat(id)
        chats.removeAll { $0.id == id }
        if chatId == id { reset() }   // deleting the open chat clears the transcript
    }

    func deleteAllChats() async {
        let ids = chats.map(\.id)
        for id in ids { try? await APIClient.shared.deleteChat(id) }
        chats = []
        reset()
    }
}

/// The AI assistant chat — a native iMessage-style transcript with a streamed
/// reply bubble, backed by the same /api/ai/chat SSE endpoint as the web app.
struct AssistantView: View {
    // Owned by RootView so streaming + transcript survive leaving this page.
    @ObservedObject var vm: AssistantViewModel
    @EnvironmentObject private var store: PortfolioStore
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var providerHasKey = AISettings.hasKey(for: AISettings.activeProvider)
    @State private var photoItem: PhotosPickerItem?
    @FocusState private var inputFocused: Bool

    // Mirrors of the persisted provider/model so the header re-renders when
    // they're switched from the in-chat menu.
    @State private var activeProvider = AISettings.activeProvider
    @State private var activeModel = AISettings.selectedModel(for: AISettings.activeProvider)

    /// Short label for the currently active model, e.g. "Gemini 2.5 Flash".
    private var activeModelLabel: String {
        activeProvider.availableModels.first { $0.id == activeModel }?.label ?? activeModel
    }

    /// Switch provider/model right from the chat header. Keys still live in
    /// Settings — picking a keyless provider routes there.
    private func select(provider: AIProvider, model: String) {
        AISettings.activeProvider = provider
        AISettings.setModel(model, for: provider)
        activeProvider = provider
        activeModel = model
        providerHasKey = AISettings.hasKey(for: provider)
        if !providerHasKey { showSettings = true }
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if !providerHasKey {
                noKeyBanner
            }
            inputBar
        }
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Tap the title to switch provider/model without a trip to
                // Settings (keys still live there).
                Menu {
                    ForEach(AIProvider.allCases) { provider in
                        Menu {
                            ForEach(provider.availableModels) { m in
                                Button {
                                    select(provider: provider, model: m.id)
                                } label: {
                                    if provider == activeProvider && m.id == activeModel {
                                        Label(m.label, systemImage: "checkmark")
                                    } else {
                                        Text(m.label)
                                    }
                                }
                            }
                        } label: {
                            if AISettings.hasKey(for: provider) {
                                Text(provider.displayName)
                            } else {
                                Label(provider.displayName, systemImage: "key")
                            }
                        }
                    }
                    Divider()
                    Button { showSettings = true } label: {
                        Label("API keys & settings…", systemImage: "gearshape")
                    }
                } label: {
                    VStack(spacing: 1) {
                        Text("Assistant")
                            .font(.headline)
                            .foregroundStyle(Theme.primaryText)
                        HStack(spacing: 3) {
                            Text("\(activeProvider.displayName) · \(activeModelLabel)")
                                .font(.system(size: 11, weight: .regular))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(Theme.mutedText)
                    }
                    .fixedSize()
                }
                // Menu freezes its label's size at first layout on some iOS
                // versions (see the holdings sort pill) — rebuild per selection
                // so the subtitle never clips.
                .id("\(activeProvider.rawValue)-\(activeModel)")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button { showHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { vm.reset() } label: { Image(systemName: "square.and.pencil") }
                    .disabled(vm.messages.isEmpty && vm.streamingText.isEmpty)
            }
            // A Done button above the keyboard so it can always be dismissed
            // (otherwise it covers the tab bar and traps the user on this page).
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { inputFocused = false }
            }
        }
        .sheet(isPresented: $showHistory) { ChatHistoryView(vm: vm) }
        .sheet(isPresented: $showSettings, onDismiss: {
            // Settings may have changed the provider/model/keys — resync.
            activeProvider = AISettings.activeProvider
            activeModel = AISettings.selectedModel(for: activeProvider)
            providerHasKey = AISettings.hasKey(for: activeProvider)
        }) { SettingsView() }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await vm.handlePickedImage(data)
                } else {
                    vm.error = "Couldn't read that image"
                }
            }
        }
        .task { await vm.loadStatus() }
        .onAppear {
            activeProvider = AISettings.activeProvider
            activeModel = AISettings.selectedModel(for: activeProvider)
            providerHasKey = AISettings.hasKey(for: activeProvider)
            // Wake a cold backend + pre-build the chat context while the user
            // is still reading/typing, so the first send streams immediately.
            Task { await APIClient.shared.prewarmAI() }
            if ProcessInfo.processInfo.environment["UITEST_HISTORY"] == "1" { showHistory = true }
        }
    }

    private var noKeyBanner: some View {
        Button { showSettings = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                Text("Add your \(AISettings.activeProvider.displayName) API key to chat")
                Spacer()
                Image(systemName: "chevron.right")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.primaryText)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Theme.accent.opacity(0.18))
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if vm.messages.isEmpty && vm.streamingText.isEmpty {
                        welcome
                    }
                    ForEach(Array(vm.messages.enumerated()), id: \.offset) { idx, msg in
                        // Keep the last reply's reasoning attached above it,
                        // collapsed but re-expandable, until the next send.
                        if idx == vm.messages.count - 1, msg.role == "assistant",
                           !vm.thinkingText.isEmpty, !vm.isStreaming {
                            ReasoningSection(text: vm.thinkingText, active: false)
                        }
                        ChatBubble(message: msg)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if vm.isStreaming {
                        Group {
                            VStack(alignment: .leading, spacing: 12) {
                                if !vm.thinkingText.isEmpty {
                                    // Live reasoning — expanded while it
                                    // streams, collapses when the answer
                                    // starts; tap to toggle anytime.
                                    ReasoningSection(text: vm.thinkingText,
                                                     active: vm.streamingText.isEmpty)
                                }
                                if vm.streamingText.isEmpty {
                                    if vm.thinkingText.isEmpty {
                                        ThinkingIndicator(text: vm.streamStatus ?? "Thinking…")
                                            .animation(.easeInOut(duration: 0.25), value: vm.streamStatus)
                                    } else if let status = vm.streamStatus {
                                        ThinkingIndicator(text: status)
                                    }
                                } else {
                                    // Trailing ▍ = the live-generation cursor.
                                    ChatBubble(message: ChatMessage(role: "assistant",
                                                                    content: vm.streamingText + " ▍"))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id("streaming")
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // In-chat image import: attached image → parsing → review card.
                    if let img = vm.importImage {
                        HStack {
                            Spacer(minLength: 60)
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    if vm.isParsingImport {
                        ThinkingIndicator(text: "Reading your image…", icon: "photo.viewfinder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if vm.pendingImport != nil {
                        ImportReviewCard(vm: vm, store: store)
                    }
                    if let error = vm.error {
                        ErrorBanner(message: error)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
                // Spring the new-message/thinking rows in instead of popping.
                .animation(.spring(response: 0.35, dampingFraction: 0.85),
                           value: vm.messages.count)
                .animation(.spring(response: 0.35, dampingFraction: 0.85),
                           value: vm.isStreaming)
            }
            // Swipe down on the transcript to dismiss the keyboard.
            .scrollDismissesKeyboard(.interactively)
            // A soft tick when a reply lands (message count grows).
            .sensoryFeedback(.impact(weight: .light), trigger: vm.messages.count)
            .onChange(of: vm.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: vm.streamingText) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: vm.thinkingText) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: vm.isParsingImport) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: vm.pendingImport == nil) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// Portfolio-aware starter prompts — tap to send. Kept short so each fits
    /// one line; they showcase the assistant's range (analysis, news via web
    /// grounding, fundamentals).
    private static let starterPrompts: [(icon: String, text: String)] = [
        ("chart.line.uptrend.xyaxis", "How is my portfolio doing today?"),
        ("trophy", "What are my best and worst performers?"),
        ("newspaper", "Any news affecting my holdings?"),
        ("scalemass", "Am I too concentrated? Review my allocation"),
        ("building.2", "Summarize 2330's latest quarter"),
    ]

    private var welcome: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 40))
                    .foregroundStyle(
                        LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.55)],
                                       startPoint: .top, endPoint: .bottom))
                    .shadow(color: Theme.accent.opacity(0.5), radius: 18)
                Text("Ask anything about your portfolio")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(Theme.primaryText)
                    .multilineTextAlignment(.center)
                Text("Portfolio-aware · Web search · Statement import")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedText)
            }

            VStack(spacing: 8) {
                ForEach(Self.starterPrompts, id: \.text) { prompt in
                    Button {
                        vm.input = prompt.text
                        vm.send()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: prompt.icon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 22)
                            Text(prompt.text)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.primaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.mutedText)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Theme.card.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!providerHasKey)
                }
            }
        }
        .padding(.top, 36)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            // Attach a brokerage screenshot — AI extracts trades/dividends in-chat.
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(vm.isParsingImport ? Theme.mutedText : Theme.secondaryText)
            }
            .disabled(vm.isParsingImport || vm.isSubmittingImport)

            // Send button lives inside the field pill (ChatGPT-style), and
            // becomes a stop button while a reply is streaming.
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Ask about your portfolio…", text: $vm.input, axis: .vertical)
                    .focused($inputFocused)
                    .lineLimit(1...5)
                    .padding(.leading, 6)
                    .padding(.vertical, 5)
                Button {
                    if vm.isStreaming { vm.stopStreaming() } else { vm.send() }
                } label: {
                    Image(systemName: vm.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(vm.isStreaming ? Theme.primaryText
                                         : vm.canSend ? Theme.accent : Theme.mutedText)
                        .contentTransition(.symbolEffect(.replace))
                }
                .disabled(!vm.isStreaming && !vm.canSend)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.cardElevated.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .padding(12)
        // Frosted compose bar over the gradient — matches the index strip
        // and the iOS-native look, instead of a flat tinted band.
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }
}

/// Collapsible reasoning section, like Claude's: a tappable "Reasoning" row
/// with a chevron. While the model is still reasoning (`active`) it stays
/// expanded and streams the thought text; when the answer starts it collapses
/// to a single row, and the user can re-expand it anytime.
private struct ReasoningSection: View {
    let text: String
    let active: Bool
    @State private var expanded: Bool
    @State private var userToggled = false

    init(text: String, active: Bool) {
        self.text = text
        self.active = active
        _expanded = State(initialValue: active)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                userToggled = true
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11, weight: .semibold))
                    Text(active ? "Reasoning…" : "Reasoning")
                        .font(.footnote.weight(.medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(Theme.mutedText)
            }
            .buttonStyle(.plain)

            if expanded {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.stroke)
                        .frame(width: 3)
                    Text(text)
                        .font(.system(size: 13, design: .serif))
                        .italic()
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Auto-collapse when reasoning finishes, unless the user pinned it
        // open themselves.
        .onChange(of: active) { _, nowActive in
            if !nowActive && !userToggled {
                withAnimation(.easeInOut(duration: 0.2)) { expanded = false }
            }
        }
    }
}

/// Bare inline "thinking" row — a pulsing accent sparkle plus a shimmering
/// status line (highlight sweeping left→right), directly in the chat flow with
/// no bubble container. The text is either the backend's live status
/// ("Searching the web…") or a generic "Thinking…".
private struct ThinkingIndicator: View {
    let text: String
    var icon: String = "sparkles"

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = (sin(t * 3) + 1) / 2
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .scaleEffect(0.9 + 0.15 * pulse)
                    .opacity(0.6 + 0.4 * pulse)
                shimmer(t)
            }
            .padding(.vertical, 6)
        }
    }

    private func shimmer(_ t: Double) -> some View {
        // Phase runs -0.4 → 1.4 so the highlight fully enters and exits.
        let phase = t.truncatingRemainder(dividingBy: 1.6) / 1.6 * 1.8 - 0.4
        return Text(text)
            // Serif to match the reply voice it precedes.
            .font(.system(size: 15, design: .serif))
            .foregroundStyle(
                LinearGradient(
                    stops: [
                        .init(color: Theme.secondaryText, location: 0),
                        .init(color: Theme.primaryText, location: 0.5),
                        .init(color: Theme.secondaryText, location: 1),
                    ],
                    startPoint: UnitPoint(x: phase - 0.35, y: 0.5),
                    endPoint: UnitPoint(x: phase + 0.35, y: 0.5)))
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    private var isUser: Bool { message.role == "user" }
    private var content: String { Self.stripMeta(message.content) }

    var body: some View {
        if isUser {
            HStack {
                Spacer(minLength: 40)
                Text(content)
                    .font(.subheadline.weight(.medium))
                    // Black text — readable on every accent style (incl. gold).
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    // Slight top-lit gradient so the bubble reads as a lit
                    // surface, not a flat color chip.
                    .background(
                        LinearGradient(
                            colors: [Theme.accent.opacity(0.92), Theme.accent],
                            startPoint: .top, endPoint: .bottom)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
        } else {
            // Assistant replies render as full-width formatted Markdown in the
            // Claude serif reading voice (typography only — app colors stay).
            MarkdownText(markdown: content, serif: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = content
                    } label: {
                        Label("Copy reply", systemImage: "doc.on.doc")
                    }
                }
        }
    }

    /// Strip the internal `<!--meta:{...}-->` header(s) the backend prepends to
    /// the canonical reply. Loops because older chats can carry more than one
    /// (models used to see the header in history and echo their own copy).
    static func stripMeta(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasPrefix("<!--meta:"), let r = out.range(of: "-->") {
            out = String(out[r.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }
}

/// Assistant-side card showing parsed trades/dividends with toggles and an
/// Add button — the in-chat version of the import review screen.
private struct ImportReviewCard: View {
    @ObservedObject var vm: AssistantViewModel
    let store: PortfolioStore

    private var selectedCount: Int {
        vm.importTradeOn.filter { $0 }.count + vm.importDividendOn.filter { $0 }.count
    }

    private var addTitle: String {
        let t = vm.importTradeOn.filter { $0 }.count
        let d = vm.importDividendOn.filter { $0 }.count
        var parts: [String] = []
        if t > 0 { parts.append("\(t) trade\(t == 1 ? "" : "s")") }
        if d > 0 { parts.append("\(d) dividend\(d == 1 ? "" : "s")") }
        return parts.isEmpty ? "Add" : "Add \(parts.joined(separator: " · "))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Here's what I found — untick anything that's wrong, then add:")
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)

            if let parsed = vm.pendingImport {
                VStack(spacing: 0) {
                    ForEach(Array(parsed.trades.enumerated()), id: \.offset) { i, row in
                        importRow(
                            isOn: Binding(
                                get: { vm.importTradeOn.indices.contains(i) ? vm.importTradeOn[i] : false },
                                set: { if vm.importTradeOn.indices.contains(i) { vm.importTradeOn[i] = $0 } }),
                            title: row.ticker,
                            tag: row.type == .buy ? "Buy" : "Sell",
                            tagColor: row.type == .buy ? Theme.positive : Theme.negative,
                            detail: "\(Fmt.shares(row.shares)) @ \(Fmt.number(row.price))",
                            date: row.date
                        )
                    }
                    ForEach(Array(parsed.dividends.enumerated()), id: \.offset) { i, row in
                        importRow(
                            isOn: Binding(
                                get: { vm.importDividendOn.indices.contains(i) ? vm.importDividendOn[i] : false },
                                set: { if vm.importDividendOn.indices.contains(i) { vm.importDividendOn[i] = $0 } }),
                            title: row.ticker,
                            tag: "Dividend",
                            tagColor: Theme.accent,
                            detail: "+\(Fmt.number(row.amount))",
                            date: row.date
                        )
                    }
                }

                if !parsed.notes.isEmpty {
                    Text(parsed.notes)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await vm.submitImport(store: store) }
                } label: {
                    Group {
                        if vm.isSubmittingImport { ProgressView().tint(.black) }
                        else {
                            Text(addTitle)
                                .font(.system(.subheadline, design: .rounded).weight(.bold))
                        }
                    }
                    .foregroundStyle(selectedCount == 0 ? Theme.mutedText : .black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(selectedCount == 0 ? Theme.cardElevated : Theme.accent)
                    .clipShape(Capsule())
                }
                .disabled(selectedCount == 0 || vm.isSubmittingImport)

                Button("Dismiss") { vm.cancelImport() }
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .cardStyle(padding: 14)
    }

    private func importRow(isOn: Binding<Bool>, title: String, tag: String,
                           tagColor: Color, detail: String, date: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("", isOn: isOn).labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(Theme.primaryText)
                        Text(tag)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(tagColor)
                    }
                    Text(date)
                        .font(.caption2)
                        .foregroundStyle(Theme.mutedText)
                }
                Spacer()
                Text(detail)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
            }
            .padding(.vertical, 8)
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }
}
