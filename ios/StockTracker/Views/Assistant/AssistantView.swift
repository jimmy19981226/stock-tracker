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

    // A photo staged in the compose bar — attached but not yet sent. The user
    // can still type a prompt to go with it; only Send actually uploads it.
    @Published var pendingAttachment: UIImage?
    private var pendingAttachmentData: Data?

    // Confirm-card flow for proposed trades/dividends: the assistant (reading
    // either typed text or an attached image) calls add_trade/add_dividend,
    // the server emits an "action" event, and this card lets the user review
    // before anything is actually saved.
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
            thinkingText = """
            The user wants a status check on their Taiwan portfolio. I pulled the \
            summary and holdings: total value NT$1.75M, up 1.83% today, with 2330 \
            carrying most of the unrealized gain. I'll lead with the totals, then \
            highlight the top contributors and dividends.
            """
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
        guard !isStreaming else { return false }
        return !input.trimmingCharacters(in: .whitespaces).isEmpty || pendingAttachment != nil
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespaces)
        let attachedImage = pendingAttachment
        let attachedData = pendingAttachmentData
        guard !isStreaming, !text.isEmpty || attachedData != nil else { return }
        input = ""
        pendingAttachment = nil
        pendingAttachmentData = nil
        error = nil
        recoverTask?.cancel()
        messages.append(ChatMessage(role: "user", content: text, localImage: attachedImage))
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
                    image: attachedData,
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
        removeAttachment()
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

    // MARK: - Image attach (in-chat)

    /// Stage a picked photo in the compose bar. Nothing is uploaded yet — the
    /// user can still type a prompt to go with it; Send uploads both together.
    func attachImage(_ rawData: Data) {
        error = nil
        guard let img = UIImage(data: rawData) else {
            self.error = "Couldn't read that image"
            return
        }
        // Downscale large photos so the upload stays small.
        let maxDim: CGFloat = 2200
        let scale = min(1, maxDim / max(img.size.width, img.size.height))
        let target = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: target)) }
        pendingAttachment = resized
        pendingAttachmentData = resized.jpegData(compressionQuality: 0.8) ?? rawData
    }

    func removeAttachment() {
        pendingAttachment = nil
        pendingAttachmentData = nil
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
        pendingImport = nil
        importTradeOn = []
        importDividendOn = []
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

/// The assistant.
///
/// A turn is shown in the order it actually happens: the question, the tools
/// the model reached for, what it was thinking, then the answer — and, when the
/// model wants to *write* something, a draft card that saves nothing until it
/// is confirmed. That last rule holds for every write tool, without exception.
struct AssistantView: View {
    // Owned by RootView so streaming + transcript survive leaving this page.
    @ObservedObject var vm: AssistantViewModel
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var settings: AppSettings
    @State private var showHistory = false
    @State private var providerHasKey = AISettings.hasKey(for: AISettings.activeProvider)
    @State private var photoItem: PhotosPickerItem?
    @FocusState private var inputFocused: Bool
    @State private var activeProvider = AISettings.activeProvider

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            inputBar
        }
        .screenBackground()
        .sheet(isPresented: $showHistory) { ChatHistoryView(vm: vm) }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    vm.attachImage(data)
                } else {
                    vm.error = "Couldn't read that image"
                }
            }
        }
        .task { await vm.loadStatus() }
        .onAppear {
            activeProvider = AISettings.activeProvider
            providerHasKey = AISettings.hasKey(for: activeProvider)
            // Wake a cold backend and pre-build the chat context while the user
            // is still reading, so the first send streams immediately.
            Task { await APIClient.shared.prewarmAI() }
            if ProcessInfo.processInfo.environment["UITEST_HISTORY"] == "1" { showHistory = true }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            IconButton(symbol: "clock") { showHistory = true }
                .accessibilityLabel("Chat history")
            Text("✦ Assistant")
                .font(Theme.Typo.headingLg)
                .foregroundStyle(Theme.text)
            Spacer(minLength: Theme.Space.xs)
            TagChip(text: activeProvider.shortName, style: .accent)
            IconButton(symbol: "square.and.pencil") { vm.reset() }
                .disabled(vm.messages.isEmpty && vm.streamingText.isEmpty)
                .accessibilityLabel("New chat")
        }
        .padding(.horizontal, Theme.Space.screenH)
        .padding(.top, Theme.Space.screenTop)
        .padding(.bottom, Theme.Space.m)
        .navChrome(edge: .bottom)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                    if vm.messages.isEmpty && vm.streamingText.isEmpty {
                        emptyState
                    }

                    ForEach(Array(vm.messages.enumerated()), id: \.offset) { index, message in
                        // The last reply's reasoning stays attached above it,
                        // collapsed but re-expandable, until the next send.
                        if index == vm.messages.count - 1, message.role == "assistant",
                           !vm.thinkingText.isEmpty, !vm.isStreaming, settings.showReasoning {
                            ReasoningBlock(text: vm.thinkingText, active: false)
                        }
                        MessageView(message: message)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if vm.isStreaming {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            if let status = vm.streamStatus {
                                ToolStatusLine(text: status)
                            }
                            if !vm.thinkingText.isEmpty, settings.showReasoning {
                                ReasoningBlock(text: vm.thinkingText,
                                               active: vm.streamingText.isEmpty)
                            }
                            if vm.streamingText.isEmpty {
                                if vm.thinkingText.isEmpty && vm.streamStatus == nil {
                                    ToolStatusLine(text: "reading your portfolio…")
                                }
                            } else {
                                AnswerView(text: vm.streamingText + " ▍")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("streaming")
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // A write tool proposed records. This card is the only way
                    // they reach the database.
                    if vm.pendingImport != nil {
                        DraftRecordsCard(vm: vm, store: store)
                    }

                    if !providerHasKey {
                        noKeyBanner
                    }
                    if let error = vm.error {
                        ErrorBanner(message: error)
                    }
                    if vm.isStreaming {
                        generatingRow
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Theme.Space.screenH)
                .padding(.vertical, Theme.Space.l)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.messages.count)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.isStreaming)
            }
            .scrollDismissesKeyboard(.interactively)
            .sensoryFeedback(.impact(weight: .light), trigger: vm.messages.count)
            .onChange(of: vm.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: vm.streamingText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: vm.thinkingText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: vm.pendingImport == nil) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// While a reply is in flight. It says the generation survives leaving the
    /// app because it does — the server finishes the turn either way — and the
    /// Stop is right there for when that isn't what you wanted.
    private var generatingRow: some View {
        HStack(spacing: Theme.Space.m) {
            PulsingCaption(text: "✦ generating" + (settings.backgroundGeneration
                ? " — continues if you leave the app" : ""))
            SecondaryButton(title: "Stop") { vm.stopStreaming() }
        }
    }

    // MARK: Empty state

    private static let suggestions = [
        "How is my portfolio doing today?",
        "Am I beating my benchmark this year?",
        "What's the latest news on my biggest holding?",
        "I bought 2,000 shares of 00919 at 24.6 today",
    ]

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Try asking").eyebrowStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(Self.suggestions, id: \.self) { prompt in
                    Button {
                        vm.input = prompt
                        vm.send()
                    } label: {
                        Text(prompt)
                            .font(Theme.Typo.detail)
                            .foregroundStyle(Theme.text)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, Theme.Space.m + 2)
                            .padding(.vertical, Theme.Space.s + 1)
                            .background(Theme.card)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                                    .stroke(Theme.line, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button,
                                                        style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!providerHasKey)
                }
            }

            Text("Typed tools — portfolio summary, holdings, trades, dividends, live quotes for any ticker, price history, TWR/XIRR/benchmark, dividend calendar, net-worth history, FX, market hours, web search. Write tools only ever draft a record for your confirmation.")
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Space.xs)
        }
        .padding(.top, Theme.Space.m)
    }

    /// Setup prompt — an invitation, not an alert, so it sits inline as a card
    /// rather than a full-bleed warning band.
    private var noKeyBanner: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "key.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.accentTint)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Add your \(activeProvider.shortName) key")
                    .font(Theme.Typo.detailMed)
                    .foregroundStyle(Theme.text)
                Text("Settings → AI assistant. The assistant can't reply without it.")
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .appCard(padding: Theme.Space.m)
    }

    // MARK: Compose

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let attachment = vm.pendingAttachment {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Image(uiImage: attachment)
                        .resizable().scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.segment,
                                                    style: .continuous))
                    Spacer()
                    Button {
                        withAnimation(.snappy(duration: 0.3)) { vm.removeAttachment() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.textSecondary, Theme.track)
                    }
                    .buttonStyle(.plain)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: Theme.Space.s) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, height: 30)
                }
                .disabled(vm.isSubmittingImport)

                TextField(vm.pendingAttachment == nil ? "Ask about your portfolio…"
                                                      : "Add a note (optional)…",
                          text: $vm.input, axis: .vertical)
                    .focused($inputFocused)
                    .lineLimit(1...5)
                    .font(Theme.Typo.body)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                            .stroke(Theme.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button,
                                                style: .continuous))
                    .onSubmit { vm.send() }

                Button {
                    if vm.isStreaming { vm.stopStreaming() } else { vm.send() }
                } label: {
                    Image(systemName: vm.isStreaming ? "stop.fill" : "paperplane.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(vm.isStreaming || vm.canSend ? Theme.accent : Theme.textTertiary)
                        .clipShape(Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(!vm.isStreaming && !vm.canSend)
            }
        }
        .padding(.horizontal, Theme.Space.screenH)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.m)
        .navChrome(edge: .top)
    }
}

// MARK: - Message parts

/// A user turn or an assistant answer.
private struct MessageView: View {
    let message: ChatMessage
    @State private var showFullScreen = false

    private var isUser: Bool { message.role == "user" }
    private var content: String { Self.stripMeta(message.content) }

    var body: some View {
        if isUser {
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                if let img = message.displayImage {
                    HStack {
                        Spacer(minLength: 40)
                        Button { showFullScreen = true } label: {
                            Image(uiImage: img)
                                .resizable().scaledToFill()
                                .frame(width: 170, height: 170)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card,
                                                            style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .fullScreenCover(isPresented: $showFullScreen) {
                        FullScreenImageViewer(image: img)
                    }
                }
                if !content.isEmpty {
                    HStack {
                        Spacer(minLength: 40)
                        Text(content)
                            .font(Theme.Typo.body)
                            .foregroundStyle(.white)
                            .padding(.horizontal, Theme.Space.l)
                            .padding(.vertical, Theme.Space.m)
                            .background(Theme.accent)
                            // 18/18/5/18: the one clipped corner points at the
                            // sender, the way every message app draws a tail
                            // without drawing a tail.
                            .clipShape(UnevenRoundedRectangle(
                                topLeadingRadius: 18, bottomLeadingRadius: 18,
                                bottomTrailingRadius: 5, topTrailingRadius: 18,
                                style: .continuous))
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            AnswerView(text: content)
        }
    }

    /// Strip the internal `<!--meta:{...}-->` header(s) the backend prepends to
    /// the canonical reply. Loops because older chats can carry more than one.
    static func stripMeta(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasPrefix("<!--meta:"), let r = out.range(of: "-->") {
            out = String(out[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }
}

/// The answer itself, plus the disclosure the answer always needs. Rendered in
/// the body face rather than a serif: a serif reading voice was tried here
/// before, as part of a wholesale restyle of this screen, and reverted.
private struct AnswerView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            MarkdownText(markdown: text, serif: false)
                .textSelection(.enabled)
            Text("Observation from your data — not investment advice.")
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button {
                UIPasteboard.general.string = text
            } label: {
                Label("Copy reply", systemImage: "doc.on.doc")
            }
        }
    }
}

/// A tool the model reached for, as it happens. One quiet line with an accent
/// dot — enough to see what it is doing, never enough to compete with the
/// answer that follows.
private struct ToolStatusLine: View {
    let text: String

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Circle().fill(Theme.accent).frame(width: 5, height: 5)
            Text(text)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Streamed reasoning: expanded while the model is still thinking, collapsed
/// once the answer starts, re-expandable forever after. Shown only when
/// "Show reasoning" is on.
private struct ReasoningBlock: View {
    let text: String
    let active: Bool
    @State private var expanded: Bool
    @State private var userToggled = false
    @State private var started = Date()

    init(text: String, active: Bool) {
        self.text = text
        self.active = active
        _expanded = State(initialValue: active)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                userToggled = true
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Reasoning \(duration)")
                        .eyebrowStyle(Theme.textStrong)
                        .tracking(11 * 0.10)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textStrong)
                .padding(.horizontal, Theme.Space.m + 2)
                .padding(.vertical, Theme.Space.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(Theme.Typo.detail)
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.m + 2)
                    .padding(.bottom, Theme.Space.m)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.track)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.inset, style: .continuous))
        .onChange(of: active) { _, nowActive in
            // Auto-collapse when the thinking ends, unless the reader pinned it.
            if !nowActive && !userToggled {
                withAnimation(.easeInOut(duration: 0.2)) { expanded = false }
            }
        }
    }

    private var duration: String {
        active ? "…" : String(format: "· %.1f s", Date().timeIntervalSince(started))
    }
}

/// A caption that breathes while work is in flight.
private struct PulsingCaption: View {
    let text: String
    @State private var dim = false

    var body: some View {
        Text(text)
            .font(Theme.Typo.detail)
            .foregroundStyle(Theme.textSecondary)
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

/// The drafted-record card.
///
/// The model can propose a trade; it cannot book one. Everything a write tool
/// produces lands here first, itemised, with every row switchable, and reaches
/// the database only when **Add** is tapped.
private struct DraftRecordsCard: View {
    @ObservedObject var vm: AssistantViewModel
    let store: PortfolioStore

    private var selectedCount: Int {
        vm.importTradeOn.filter { $0 }.count + vm.importDividendOn.filter { $0 }.count
    }

    private var addTitle: String {
        let trades = vm.importTradeOn.filter { $0 }.count
        let divs = vm.importDividendOn.filter { $0 }.count
        var parts: [String] = []
        if trades > 0 { parts.append("\(trades) trade\(trades == 1 ? "" : "s")") }
        if divs > 0 { parts.append("\(divs) dividend\(divs == 1 ? "" : "s")") }
        return parts.isEmpty ? "Add" : "Add \(parts.joined(separator: " · "))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("Drafted — confirm to save").eyebrowStyle(Theme.accent)
                Spacer(minLength: Theme.Space.s)
            }

            if let parsed = vm.pendingImport {
                VStack(spacing: 0) {
                    ForEach(Array(parsed.trades.enumerated()), id: \.offset) { i, row in
                        draftRow(
                            isOn: Binding(
                                get: { vm.importTradeOn.indices.contains(i) ? vm.importTradeOn[i] : false },
                                set: { if vm.importTradeOn.indices.contains(i) { vm.importTradeOn[i] = $0 } }),
                            tag: row.type == .buy ? "BUY" : "SELL",
                            style: row.type == .buy ? .accent : .outline,
                            ticker: row.ticker,
                            detail: "\(Fmt.shares(row.shares)) @ \(Fmt.number(row.price, digits: 2))"
                                + " · \(row.date.prefix(10))"
                                + (row.fee.map { " · fee \(Fmt.number($0, digits: 0))" } ?? ""),
                            last: i == parsed.trades.count - 1 && parsed.dividends.isEmpty)
                    }
                    ForEach(Array(parsed.dividends.enumerated()), id: \.offset) { i, row in
                        draftRow(
                            isOn: Binding(
                                get: { vm.importDividendOn.indices.contains(i) ? vm.importDividendOn[i] : false },
                                set: { if vm.importDividendOn.indices.contains(i) { vm.importDividendOn[i] = $0 } }),
                            tag: "DIV", style: .neutral,
                            ticker: row.ticker,
                            detail: "\(Fmt.number(row.amount, digits: 2)) · \(row.date.prefix(10))",
                            last: i == parsed.dividends.count - 1)
                    }
                }

                if !parsed.notes.isEmpty {
                    Text(parsed.notes)
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            HStack(spacing: Theme.Space.s) {
                PrimaryButton(title: addTitle,
                              disabled: selectedCount == 0,
                              busy: vm.isSubmittingImport) {
                    Task { await vm.submitImport(store: store) }
                }
                SecondaryButton(title: "Discard") { vm.cancelImport() }
            }
        }
        .appCard()
    }

    private func draftRow(isOn: Binding<Bool>, tag: String, style: TagChip.Style,
                          ticker: String, detail: String, last: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                TagChip(text: tag, style: style, width: 46)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ticker)
                        .font(Theme.Typo.row)
                        .foregroundStyle(Theme.text)
                    Text(detail)
                        .font(Theme.Typo.micro)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Space.s)
                Toggle("", isOn: isOn).labelsHidden().tint(Theme.accent)
            }
            .padding(.vertical, Theme.Space.s)
            if !last { RowDivider(inset: 0) }
        }
    }
}

/// Full-screen, pinch-to-zoom review of a chat-attached photo.
private struct FullScreenImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable().scaledToFit()
                .scaleEffect(zoom)
                .gesture(
                    MagnificationGesture()
                        .onChanged { zoom = max(1, min($0, 4)) }
                        .onEnded { _ in withAnimation(.snappy) { if zoom < 1.05 { zoom = 1 } } }
                )
                .onTapGesture { dismiss() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white, Color.black.opacity(0.4))
            }
            .padding(20)
        }
    }
}
