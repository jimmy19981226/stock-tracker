import PhotosUI
import SwiftUI
import UIKit

/// Each background allowance belongs to one generation. Injectable handlers
/// let unit tests exercise cancellation races without changing app lifecycle.
struct AssistantBackgroundTasks {
    var begin: (@escaping () -> Void) -> UIBackgroundTaskIdentifier
    var end: (UIBackgroundTaskIdentifier) -> Void

    static let live = AssistantBackgroundTasks(
        begin: { expiration in
            UIApplication.shared.beginBackgroundTask(withName: "ai-generation", expirationHandler: expiration)
        },
        end: { UIApplication.shared.endBackgroundTask($0) }
    )
}

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

    // Confirm-card flow. A write tool never touches the database: it proposes,
    // the server emits an "action" event, and this card is the only path from
    // a proposal to a record. Creates, corrections and deletions all land here.
    @Published var pendingImport: RecordProposal?
    @Published var importTradeOn: [Bool] = []
    @Published var importDividendOn: [Bool] = []
    @Published var isSubmittingImport = false

    /// Report jobs the assistant started, oldest first. The card lives in the
    /// transcript; the polling lives in `ReportsStore`, which outlives the tab.
    @Published var reportIDs: [String] = []

    private let api: APIClient
    private let backgroundTasks: AssistantBackgroundTasks
    private let refreshPortfolio: (PortfolioStore) async -> Void
    private var conversationRevision = UUID()
    private var activeRunID: UUID?
    private var historyRequestID: UUID?
    private var bgTaskOwner: UUID?
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

    init(api: APIClient = .shared, backgroundTasks: AssistantBackgroundTasks = .live,
         refreshPortfolio: @escaping (PortfolioStore) async -> Void = { await $0.loadAll() }) {
        self.api = api
        self.backgroundTasks = backgroundTasks
        self.refreshPortfolio = refreshPortfolio
        if ProcessInfo.processInfo.environment["UITEST_CHAT_FORMAT"] == "1" {
            messages = [
                ChatMessage(role: "user", content: "Show my positions and explain the figures."),
                ChatMessage(role: "assistant", content: """
                <!--meta:{"queries":[]}-->
                ## Your portfolio review

                **Two markets.** Each amount keeps its original currency.

                Market | Position | Shares | Value | Profit
                --- | --- | ---: | ---: | ---:
                TW | 台積電 2330 | 230 | NT$552,000 | NT$13,389
                US | Apple AAPL | 10.125 | US$2,026.27 | US$98.99

                - **Profit** includes the recorded purchase costs.
                - Missing prices appear as **Unavailable**.

                [Source details](https://example.com/portfolio)
                """)
            ]
        }
        // UI-test hook: seed a markdown-table reply to screenshot the renderer.
        if ProcessInfo.processInfo.environment["UITEST_CHAT_LONG_NAME"] == "1" {
            messages = [ChatMessage(role: "assistant", content: """
            Metric | Value
            --- | ---
            US · Largest name | Taiwan Semiconductor Manufacturing Company Limited
            US · Largest share | 42.21%
            Today's gain | US$1,234.56
            """)]
        }
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
            present(RecordProposal.demoBatch)
        }
        // UI-test hooks for the correction and deletion cards.
        if ProcessInfo.processInfo.environment["UITEST_CHAT_EDIT"] == "1" {
            messages = [ChatMessage(role: "user",
                                    content: "That 2330 buy should have been 1,035, not 1,053.")]
            present(RecordProposal.demoEdit)
        }
        if ProcessInfo.processInfo.environment["UITEST_CHAT_REPORT"] == "1" {
            messages = [
                ChatMessage(role: "user", content: "Give me a dividend report for this year."),
                ChatMessage(role: "assistant",
                            content: "Taiwan NT$86,372 net across 5 payments; US US$113.40 net across 2. The full breakdown is in the report."),
            ]
            Task { @MainActor in
                if let job = await ReportsStore.shared.generate(
                    template: "dividend_year", period: "ytd") {
                    reportIDs = [job.reportID]
                }
            }
        }
        if ProcessInfo.processInfo.environment["UITEST_CHAT_LEGACY"] == "1" {
            messages = [ChatMessage(role: "user", content: "I bought 100 of 2330 at 1050.")]
            present(RecordProposal.demoLegacy)
        }
        if ProcessInfo.processInfo.environment["UITEST_CHAT_DELETE"] == "1" {
            messages = [ChatMessage(role: "user", content: "Delete that duplicate 2603 buy.")]
            present(RecordProposal.demoDelete)
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

    /// Show a proposal's confirm card.
    ///
    /// The one way a proposal reaches the UI — the live stream and the
    /// screenshot hooks both go through here, so a card in a screenshot is a
    /// card the wire format actually produces. Rows the server flagged as
    /// duplicating an existing record arrive **unticked**: a statement
    /// photographed twice is the common case, and a silently doubled lot is
    /// expensive to notice later.
    func present(_ proposal: RecordProposal) {
        pendingImport = proposal
        importTradeOn = proposal.trades.map { $0.duplicateOf == nil }
        importDividendOn = proposal.dividends.map { $0.duplicateOf == nil }
    }

    func loadStatus() async {
        status = try? await api.getAiStatus()
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
        historyRequestID = nil
        recoverTask?.cancel()
        let runID = UUID()
        activeRunID = runID
        let requestedChatID = chatId
        messages.append(ChatMessage(role: "user", content: text, localImage: attachedImage))
        isStreaming = true
        streamingText = ""
        thinkingText = ""
        beginBackgroundTask(for: runID)
        // Server truth after this turn completes: everything local so far
        // plus the assistant reply — used by recovery to know it landed.
        let expectedCount = messages.count + 1

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await api.streamChat(
                    chatId: requestedChatID,
                    message: text,
                    image: attachedData,
                    onInit: { [weak self] id, _ in
                        guard let self, self.activeRunID == runID, !Task.isCancelled else { return }
                        self.chatId = id
                    },
                    onChunk: { [weak self] delta in
                        guard let self, self.activeRunID == runID, !Task.isCancelled else { return }
                        self.streamStatus = nil
                        self.streamingText += delta
                    },
                    onDone: { [weak self] content, _ in
                        guard let self, self.activeRunID == runID, !Task.isCancelled else { return }
                        let final = content.isEmpty ? self.streamingText : content
                        self.messages.append(ChatMessage(role: "assistant", content: final))
                        self.streamingText = ""
                        self.streamStatus = nil
                    },
                    onStatus: { [weak self] text in
                        guard let self, self.activeRunID == runID, !Task.isCancelled else { return }
                        self.streamStatus = text
                    },
                    onAction: { [weak self] proposal in
                        guard let self, self.activeRunID == runID, !Task.isCancelled else { return }
                        // A write tool proposed records. Nothing is saved until
                        // the user confirms this card. Rows the server flagged
                        // as duplicating an existing record arrive unticked —
                        // a statement photographed twice is the common case,
                        // and a silently doubled lot is expensive to notice.
                        self.present(proposal)
                    },
                    onReport: { [weak self] job in
                        guard let self, self.activeRunID == runID, !Task.isCancelled else { return }
                        // `generate_report` proposes nothing — the document is
                        // already rendering. The card tracks it to ready.
                        ReportsStore.shared.adopt(job)
                        if !self.reportIDs.contains(job.reportID) {
                            self.reportIDs.append(job.reportID)
                        }
                    },
                    onThinking: { [weak self] delta in
                        guard let self, self.activeRunID == runID, !Task.isCancelled else { return }
                        self.streamStatus = nil
                        self.thinkingText += delta
                    }
                )
            } catch {
                // A cancelled stream is an intentional teardown, not an error.
                if self.activeRunID == runID, !Task.isCancelled {
                    self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
                    if !self.streamingText.isEmpty {
                        self.messages.append(ChatMessage(role: "assistant", content: self.streamingText))
                        self.streamingText = ""
                    }
                    // The server keeps generating even though our stream died
                    // (e.g. the app was backgrounded past the grace window) —
                    // poll until the finished reply lands, then swap it in.
                    self.startRecovery(expectedCount: expectedCount, runID: runID)
                }
            }
            if self.activeRunID == runID, !Task.isCancelled {
                self.isStreaming = false
                self.streamTask = nil
            }
            self.endBackgroundTask(for: runID)
        }
    }

    /// Stop generation mid-stream, keeping whatever has arrived as the reply.
    /// Also cancels the server-side run so it stops burning tokens.
    func stopStreaming() {
        activeRunID = nil
        streamTask?.cancel()
        streamTask = nil
        recoverTask?.cancel()
        if let id = chatId {
            Task { try? await api.stopChat(id) }
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
        conversationRevision = UUID()
        activeRunID = nil
        historyRequestID = nil
        streamTask?.cancel()
        streamTask = nil
        recoverTask?.cancel()
        chatId = nil
        input = ""
        reportIDs = []
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

    private func beginBackgroundTask(for runID: UUID) {
        endBackgroundTask()
        bgTaskOwner = runID
        bgTaskId = backgroundTasks.begin { [weak self] in
            Task { @MainActor in self?.endBackgroundTask(for: runID) }
        }
    }

    private func endBackgroundTask(for runID: UUID? = nil) {
        if let runID, bgTaskOwner != runID { return }
        if bgTaskId != .invalid { backgroundTasks.end(bgTaskId) }
        bgTaskId = .invalid
        bgTaskOwner = nil
    }

    /// Fetch the chat until the server-persisted reply appears (generation
    /// finishes server-side even with no client attached), then replace the
    /// local transcript with the canonical one.
    private func startRecovery(expectedCount: Int, runID: UUID) {
        guard let id = chatId else { return }
        recoverTask?.cancel()
        recoverTask = Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.activeRunID == runID, !Task.isCancelled else { return }
                if let detail = try? await self.api.getChat(id),
                   self.activeRunID == runID, self.chatId == id, !Task.isCancelled,
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
        let format = UIGraphicsImageRendererFormat()
        // The limit is in image pixels, independent of the phone's 2x/3x
        // display scale. The default renderer would enlarge the upload again.
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: target)) }
        pendingAttachment = resized
        pendingAttachmentData = resized.jpegData(compressionQuality: 0.8) ?? rawData
    }

    func removeAttachment() {
        pendingAttachment = nil
        pendingAttachmentData = nil
    }

    /// Write the rows the user kept, each through the ordinary REST endpoint —
    /// the same call the form sheet makes. The assistant proposes; this is the
    /// only code that writes.
    func submitImport(store: PortfolioStore) async {
        guard let proposal = pendingImport, !isSubmittingImport else { return }
        let submittedConversation = conversationRevision
        // Confirmation authorizes this exact selection. Navigating elsewhere
        // must not mutate the remaining batch while its requests are in flight.
        let selectedTrades = importTradeOn
        let selectedDividends = importDividendOn
        isSubmittingImport = true
        var created = 0, updated = 0, deleted = 0, failures = 0

        for (i, row) in proposal.trades.enumerated()
        where selectedTrades.indices.contains(i) && selectedTrades[i] {
            do {
                switch row.op {
                case .create:
                    _ = try await api.createTrade(row.createPayload())
                    created += 1
                case .update:
                    guard let id = row.recordID else { failures += 1; break }
                    _ = try await api.updateTrade(id, row.createPayload())
                    updated += 1
                case .delete:
                    guard let id = row.recordID else { failures += 1; break }
                    try await api.deleteTrade(id)
                    deleted += 1
                }
            } catch { failures += 1 }
        }

        for (i, row) in proposal.dividends.enumerated()
        where selectedDividends.indices.contains(i) && selectedDividends[i] {
            do {
                switch row.op {
                case .create:
                    _ = try await api.createDividend(row.createPayload())
                    created += 1
                case .update:
                    guard let id = row.recordID else { failures += 1; break }
                    _ = try await api.updateDividend(id, row.createPayload())
                    updated += 1
                case .delete:
                    guard let id = row.recordID else { failures += 1; break }
                    try await api.deleteDividend(id)
                    deleted += 1
                }
            } catch { failures += 1 }
        }

        await refreshPortfolio(store)
        // The confirmed writes still finish and refresh the app-wide store, but
        // their receipt cannot replace a proposal in a different conversation.
        guard conversationRevision == submittedConversation else { return }

        var parts: [String] = []
        if created > 0 { parts.append("added \(created) record\(created == 1 ? "" : "s")") }
        if updated > 0 { parts.append("updated \(updated)") }
        if deleted > 0 { parts.append("deleted \(deleted)") }
        var summary = parts.isEmpty ? "Nothing was changed." : "✅ " + parts.joined(separator: ", ") + "."
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
        chats = (try? await api.listChats()) ?? []
        loadingChats = false
    }

    /// Open a past conversation into the transcript.
    func openChat(_ id: Int) async {
        if id == chatId { return }
        let requestID = UUID()
        historyRequestID = requestID
        guard let detail = try? await api.getChat(id),
              historyRequestID == requestID, !Task.isCancelled else { return }
        reset()
        messages = detail.messages
        chatId = detail.id
    }

    func deleteChat(_ id: Int) async {
        try? await api.deleteChat(id)
        chats.removeAll { $0.id == id }
        if chatId == id { reset() }   // deleting the open chat clears the transcript
    }

    func deleteAllChats() async {
        let ids = chats.map(\.id)
        for id in ids { try? await api.deleteChat(id) }
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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || ProcessInfo.processInfo.environment["UITEST_REDUCE_MOTION"] == "1" }
    @ObservedObject private var reports = ReportsStore.shared
    @State private var showHistory = false
    @State private var providerHasKey = AISettings.usePersonalKey && AISettings.hasKey
    @State private var photoItem: PhotosPickerItem?
    @FocusState private var inputFocused: Bool
    @State private var runStarted = Date()

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
        .onChange(of: vm.isStreaming) { _, streaming in
            if streaming { inputFocused = false; runStarted = Date() }
        }
        .sensoryFeedback(.success, trigger: vm.isStreaming) { previous, current in
            previous && !current && vm.error == nil && !vm.streamingText.isEmpty
        }
        .onAppear {
            providerHasKey = AISettings.usePersonalKey && AISettings.hasKey
            // Wake a cold backend and pre-build the chat context while the user
            // is still reading, so the first send streams immediately.
            Task { await APIClient.shared.prewarmAI() }
            if ProcessInfo.processInfo.environment["UITEST_HISTORY"] == "1" { showHistory = true }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "sparkles")
                .font(Theme.Typo.headingSm)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(Theme.accent)
                .frame(width: Theme.Assistant.mark, height: Theme.Assistant.mark)
                .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("Assistant")
                    .font(Theme.Typo.heading)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(Theme.text)
                Text(AISettings.modelLabel)
                    .font(Theme.Typo.micro).foregroundStyle(Theme.textSecondary)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: Theme.Space.xs)
            IconButton(symbol: "clock.arrow.circlepath") { showHistory = true }
                .accessibilityLabel("Chat history")
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
                LazyVStack(alignment: .leading, spacing: Theme.Space.cardGap) {
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
                        if index == vm.messages.count - 1, message.role == "assistant",
                           !vm.isStreaming, vm.error == nil, vm.pendingImport == nil {
                            followUpActions
                        }
                    }

                    if vm.isStreaming {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            generatingRow
                            if !vm.thinkingText.isEmpty, settings.showReasoning {
                                ReasoningBlock(text: vm.thinkingText,
                                               active: vm.streamingText.isEmpty)
                            }
                            if !vm.streamingText.isEmpty {
                                AnswerView(text: vm.streamingText + " ▍", isStreaming: true)
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

                    ForEach(vm.reportIDs, id: \.self) { id in
                        if let job = reports.job(id) {
                            ReportCardView(job: job,
                                           onOpen: { reports.open($0) },
                                           onRetry: { job in
                                               Task { await reports.retry(job) }
                                           })
                        }
                    }

                    if !providerHasKey && vm.status?.configured == false {
                        noKeyBanner
                    }
                    if let error = vm.error {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            ErrorBanner(message: error)
                            if let question = vm.messages.last(where: { $0.role == "user" }), !question.content.isEmpty {
                                Button {
                                    vm.input = question.content
                                    inputFocused = true
                                } label: {
                                    Label("Edit question and retry", systemImage: "arrow.counterclockwise")
                                        .font(Theme.Typo.button).foregroundStyle(Theme.accent)
                                        .frame(minHeight: Theme.Assistant.control)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Theme.Space.screenH)
                .padding(.vertical, Theme.Space.l)
                .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: vm.messages.count)
                .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: vm.isStreaming)
            }
            .scrollDismissesKeyboard(.interactively)
            .sensoryFeedback(.impact(weight: .light), trigger: vm.messages.count)
            .onChange(of: vm.messages.count) { _, _ in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: vm.streamingText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: vm.thinkingText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: vm.pendingImport == nil) { _, _ in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// While a reply is in flight. It says the generation survives leaving the
    /// app because it does — the server finishes the turn either way — and the
    /// Stop is right there for when that isn't what you wanted.
    private var generatingRow: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "sparkles")
                .font(Theme.Typo.headingSm).foregroundStyle(Theme.accent)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(vm.streamingText.isEmpty ? (vm.streamStatus ?? "Connecting to your portfolio…") : "Writing your answer…")
                    .font(Theme.Typo.detailMed).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("assistant.progress")
                TimelineView(.periodic(from: runStarted, by: 1)) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(runStarted)))
                    Text(elapsed >= 30 ? "Still working · \(elapsed)s" : "Working on your answer · \(elapsed)s")
                        .font(Theme.Typo.micro).monospacedDigit().foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: Theme.Space.xs)
        }
        .appCard(padding: Theme.Space.l, radius: Theme.Radius.inset)
    }

    private var followUpActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s) { followUpButtons }
            VStack(alignment: .leading, spacing: Theme.Space.s) { followUpButtons }
        }
    }

    @ViewBuilder private var followUpButtons: some View {
        ForEach(["Explain this simply", "What should I review?"], id: \.self) { prompt in
            Button {
                vm.input = prompt
                inputFocused = true
            } label: {
                Label(prompt, systemImage: "arrow.turn.down.right")
                    .font(Theme.Typo.captionMed)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, Theme.Space.m)
                    .frame(minHeight: Theme.Assistant.control)
                    .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: Theme.Radius.segment))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("assistant.followUp.\(prompt)")
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
        VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("YOUR PORTFOLIO, IN FOCUS")
                    .font(Theme.Typo.eyebrow).foregroundStyle(Theme.textSecondary)
                Text("Less noise.\nMore understanding.")
                    .font(Theme.Typo.title).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("assistant.welcome")
                Text("Ask a question. Explore your holdings. Make sense of what changed.")
                    .font(Theme.Typo.detail).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                vm.input = Self.suggestions[0]
                inputFocused = true
            } label: {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    HStack {
                        Image(systemName: "sun.max")
                            .font(Theme.Typo.heading).foregroundStyle(Theme.heroText)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(Theme.Typo.headingSm).foregroundStyle(Theme.heroLabel)
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("Your daily briefing").font(Theme.Typo.heading).foregroundStyle(Theme.heroText)
                        Text("A clear view of today's performance, across your markets.")
                            .font(Theme.Typo.detail).foregroundStyle(Theme.heroLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .heroCard(padding: Theme.Space.screenH)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Your daily briefing. What moved your portfolio today")
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("EXPLORE WITH ASSISTANT").font(Theme.Typo.eyebrow).foregroundStyle(Theme.textSecondary)
                suggestion("Compare performance", detail: "See how you track against your benchmark", icon: "chart.xyaxis.line", prompt: Self.suggestions[1])
                suggestion("Research a holding", detail: "Find context on your largest investment", icon: "text.magnifyingglass", prompt: Self.suggestions[2])
            }
            Label("You review every record before it is saved.", systemImage: "checkmark.shield")
                .font(Theme.Typo.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.m)
    }

    private func suggestion(_ title: String, detail: String, icon: String, prompt: String) -> some View {
        Button {
            vm.input = prompt
            inputFocused = true
        } label: {
            HStack(spacing: Theme.Space.l) {
                Image(systemName: icon).font(Theme.Typo.headingSm)
                    .foregroundStyle(Theme.accent).frame(width: Theme.Assistant.mark)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(title).font(Theme.Typo.row).foregroundStyle(Theme.text)
                    Text(detail).font(Theme.Typo.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left").font(Theme.Typo.caption).foregroundStyle(Theme.textTertiary)
            }
            .appCard(padding: Theme.Space.xl)
        }
        .buttonStyle(.plain)
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
                Text("Add your Gemini key")
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
                    Image(systemName: "photo.badge.plus")
                        .font(Theme.Typo.headingSm)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: Theme.Assistant.control, height: Theme.Assistant.control)
                }
                .disabled(vm.isSubmittingImport)
                .accessibilityLabel("Attach a screenshot")

                TextField(vm.pendingAttachment == nil ? "Ask about your portfolio…"
                                                      : "Add a note (optional)…",
                          text: $vm.input, axis: .vertical)
                    .focused($inputFocused)
                    .lineLimit(1...5)
                    .font(Theme.Typo.body)
                    .foregroundStyle(Theme.text)
                    .padding(.vertical, Theme.Space.m)
                    .onSubmit { vm.send() }
                    .accessibilityIdentifier("assistantComposer")

                Button {
                    if vm.isStreaming { vm.stopStreaming() } else { vm.send() }
                } label: {
                    Image(systemName: vm.isStreaming ? "stop.fill" : "arrow.up")
                        .font(Theme.Typo.button)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(vm.isStreaming || vm.canSend ? Theme.onAccent : Theme.textTertiary)
                        .frame(width: Theme.Assistant.control, height: Theme.Assistant.control)
                        .background(vm.isStreaming || vm.canSend ? Theme.accent : Theme.track)
                        .clipShape(Circle())
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(!vm.isStreaming && !vm.canSend)
                .accessibilityLabel(vm.isStreaming ? "Stop response" : "Send message")
                .accessibilityIdentifier("assistantSend")
            }
            .padding(Theme.Space.xs)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
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
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, Theme.Space.l)
                            .padding(.vertical, Theme.Space.m)
                            .background(Theme.accentTint)
                            // 18/18/5/18: the one clipped corner points at the
                            // sender, the way every message app draws a tail
                            // without drawing a tail.
                            .clipShape(UnevenRoundedRectangle(
                                topLeadingRadius: Theme.Radius.card, bottomLeadingRadius: Theme.Radius.card,
                                bottomTrailingRadius: Theme.Radius.pill, topTrailingRadius: Theme.Radius.card,
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
    var isStreaming = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || ProcessInfo.processInfo.environment["UITEST_REDUCE_MOTION"] == "1" }
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "sparkles")
                    .font(Theme.Typo.detailMed).foregroundStyle(Theme.accent)
                Text("STUDIO").font(Theme.Typo.eyebrow).foregroundStyle(Theme.textSecondary)
                Spacer()
                if !isStreaming {
                    Button {
                        UIPasteboard.general.string = text
                        withAnimation(reduceMotion ? nil : .snappy) { copied = true }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(Theme.Typo.detail)
                            .foregroundStyle(copied ? Theme.accent : Theme.textSecondary)
                            .frame(width: Theme.Assistant.control, height: Theme.Assistant.control)
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copied ? "Reply copied" : "Copy reply")
                    .sensoryFeedback(.success, trigger: copied)
                    .task(id: copied) {
                        guard copied else { return }
                        try? await Task.sleep(for: .seconds(2))
                        if !Task.isCancelled { copied = false }
                    }
                }
            }
            MarkdownText(markdown: text, serif: false)
                .textSelection(.enabled)
                .lineSpacing(Theme.Space.xxs)
            if !isStreaming {
                Text("Observation from your data — not investment advice.")
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.textSecondary)
            }
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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || ProcessInfo.processInfo.environment["UITEST_REDUCE_MOTION"] == "1" }

    init(text: String, active: Bool) {
        self.text = text
        self.active = active
        _expanded = State(initialValue: active)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                userToggled = true
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expanded.toggle() }
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
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expanded = false }
            }
        }
    }

    private var duration: String {
        active ? "…" : String(format: "· %.1f s", Date().timeIntervalSince(started))
    }
}

/// A caption that breathes while work is in flight. Shared with the report
/// card, which has the same job to describe.
struct PulsingCaption: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || ProcessInfo.processInfo.environment["UITEST_REDUCE_MOTION"] == "1" }
    @State private var dim = false

    var body: some View {
        Text(text)
            .font(Theme.Typo.detail)
            .foregroundStyle(Theme.textSecondary)
            .opacity(dim && !reduceMotion ? 0.6 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = !reduceMotion }
    }
}

/// The write card.
///
/// The model can propose a record; it cannot book one. Everything a write tool
/// produces lands here first and reaches the database only on confirmation —
/// which is why the footer says so on every variant, without exception.
///
/// Four shapes, because the question each asks is different: "is this right?"
/// for a new record, "is this the change you meant?" for a correction, "do you
/// want this gone?" for a deletion, and "which of these?" for a batch.
private struct DraftRecordsCard: View {
    @ObservedObject var vm: AssistantViewModel
    let store: PortfolioStore

    private var proposal: RecordProposal { vm.pendingImport ?? RecordProposal() }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            switch proposal.shape {
            case .update: EditBody(proposal: proposal)
            case .delete: DeleteBody(proposal: proposal)
            case .create, .batch: BatchBody(vm: vm, proposal: proposal)
            }

            if !proposal.notes.isEmpty && proposal.notes != proposal.summary {
                Text(proposal.notes)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Nothing is saved until you confirm")
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.textSecondary)

            actions
        }
        .appCard()
    }

    // MARK: Actions
    //
    // The primary button states its consequence in words. "Confirm" and "OK"
    // ask the reader to remember what they are agreeing to.

    @ViewBuilder
    private var actions: some View {
        switch proposal.shape {
        case .update:
            HStack(spacing: Theme.Space.s) {
                PrimaryButton(title: "Save change", busy: vm.isSubmittingImport) { submit() }
                SecondaryButton(title: "Discard") { vm.cancelImport() }
            }
        case .delete:
            // The one card where the destructive action is not the default
            // focus: keeping the record sits first, and the delete names the
            // object rather than saying "Confirm".
            HStack(spacing: Theme.Space.s) {
                SecondaryButton(title: "Keep it", fullWidth: true) { vm.cancelImport() }
                DestructiveButton(title: deleteTitle, busy: vm.isSubmittingImport) { submit() }
            }
        case .create, .batch:
            HStack(spacing: Theme.Space.s) {
                PrimaryButton(title: addTitle, disabled: selectedCount == 0,
                              busy: vm.isSubmittingImport) { submit() }
                SecondaryButton(title: "Discard") { vm.cancelImport() }
            }
        }
    }

    private func submit() { Task { await vm.submitImport(store: store) } }

    private var deleteTitle: String {
        proposal.trades.isEmpty ? "Delete this dividend" : "Delete this trade"
    }

    private var selectedCount: Int {
        vm.importTradeOn.filter { $0 }.count + vm.importDividendOn.filter { $0 }.count
    }

    /// Carries the live count, recomputed as the toggles change.
    private var addTitle: String {
        let n = selectedCount
        if n == 0 { return "Nothing selected" }
        return proposal.count == 1 ? "Add this record" : "Add \(n) record\(n == 1 ? "" : "s")"
    }
}

/// The correction card: only the fields that move, old struck through, new
/// beside it. Re-listing unchanged values would make the reader hunt for the
/// edit they asked for.
private struct EditBody: View {
    let proposal: RecordProposal

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Correction — confirm to save").eyebrowStyle(Theme.accent)

            if let trade = proposal.trades.first {
                header(tag: trade.displayType == .buy ? "BUY" : "SELL",
                       style: trade.displayType == .buy ? .accent : .outline,
                       ticker: trade.displayTicker)
                diff(before: trade.before, after: trade.after,
                     currency: trade.displayMarket.currencyCode)
            } else if let dividend = proposal.dividends.first {
                header(tag: "DIV", style: .neutral, ticker: dividend.displayTicker)
                diff(before: dividend.before, after: dividend.after,
                     currency: dividend.displayMarket.currencyCode)
            }
        }
    }

    private func header(tag: String, style: TagChip.Style, ticker: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            TagChip(text: tag, style: style, width: 46)
            Text(ticker)
                .font(Theme.Typo.row)
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func diff(before: [String: JSONValue]?, after: [String: JSONValue]?,
                      currency: String) -> some View {
        let keys = ProposalFormat.ordered((after ?? [:]).keys)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(keys, id: \.self) { key in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(ProposalFormat.label(key))
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: Theme.Space.s)
                    Text(ProposalFormat.value(before?[key], key: key, currency: currency))
                        .font(Theme.Typo.inlineNum)
                        .foregroundStyle(Theme.textTertiary)
                        .strikethrough()
                        .numeral()
                    Text("→")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.textTertiary)
                    Text(ProposalFormat.value(after?[key], key: key, currency: currency))
                        .font(Theme.Typo.inlineNum)
                        .foregroundStyle(Theme.text)
                        .numeral()
                }
            }
        }
    }
}

/// The deletion card: the record in full, plus whatever else the deletion
/// moves. Those consequence lines are computed by the server replaying cost basis
/// without the row — the model never authors them.
private struct DeleteBody: View {
    let proposal: RecordProposal

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Delete — confirm to remove").eyebrowStyle(Theme.loss)

            if let trade = proposal.trades.first {
                header(tag: trade.displayType == .buy ? "BUY" : "SELL",
                       style: trade.displayType == .buy ? .accent : .outline,
                       ticker: trade.displayTicker)
                detail(trade.record, keys: ["date", "shares", "price", "fee", "market"],
                       currency: trade.displayMarket.currencyCode)
                consequences(trade.consequences)
            } else if let dividend = proposal.dividends.first {
                header(tag: "DIV", style: .neutral, ticker: dividend.displayTicker)
                detail(dividend.record, keys: ["date", "amount", "market"],
                       currency: dividend.displayMarket.currencyCode)
                consequences(dividend.consequences)
            }
        }
    }

    private func header(tag: String, style: TagChip.Style, ticker: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            TagChip(text: tag, style: style, width: 46)
            Text(ticker)
                .font(Theme.Typo.row)
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
        }
    }

    private func detail(_ record: [String: JSONValue]?, keys: [String],
                        currency: String) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                KeyValueRow(ProposalFormat.label(key),
                            ProposalFormat.value(record?[key], key: key, currency: currency))
                    .padding(.vertical, 6)
                if index < keys.count - 1 { RowDivider(inset: 0) }
            }
        }
    }

    @ViewBuilder
    private func consequences(_ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.loss)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
            .background(Theme.loss.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.inset, style: .continuous))
        }
    }
}

/// The batch card: one row per proposed record, each with its own switch.
/// Rows the server flagged as duplicating an existing record arrive unticked
/// and say why.
private struct BatchBody: View {
    @ObservedObject var vm: AssistantViewModel
    let proposal: RecordProposal

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(proposal.summary.isEmpty
                 ? (proposal.count == 1 ? "Drafted — confirm to save"
                                        : "Drafted \(proposal.count) records — confirm to save")
                 : proposal.summary)
                .eyebrowStyle(Theme.accent)

            VStack(spacing: 0) {
                ForEach(Array(proposal.trades.enumerated()), id: \.offset) { index, row in
                    ProposalRow(
                        tag: row.op == .delete ? "DEL" : (row.displayType == .buy ? "BUY" : "SELL"),
                        style: row.displayType == .buy ? .accent : .outline,
                        ticker: row.displayTicker,
                        detail: ProposalFormat.tradeDetail(row),
                        duplicate: row.duplicateOf != nil,
                        duplicateDate: row.date ?? row.string("date"),
                        isOn: binding(index, \.importTradeOn))
                    if index < proposal.trades.count - 1 || !proposal.dividends.isEmpty {
                        RowDivider(inset: 0)
                    }
                }
                ForEach(Array(proposal.dividends.enumerated()), id: \.offset) { index, row in
                    ProposalRow(
                        tag: row.op == .delete ? "DEL" : "DIV",
                        style: .neutral,
                        ticker: row.displayTicker,
                        detail: ProposalFormat.dividendDetail(row),
                        duplicate: row.duplicateOf != nil,
                        duplicateDate: row.date ?? row.string("date"),
                        isOn: binding(index, \.importDividendOn))
                    if index < proposal.dividends.count - 1 { RowDivider(inset: 0) }
                }
            }
        }
    }

    /// Bound to the view model's include arrays, tolerating an index the
    /// arrays haven't caught up with (a proposal replaced mid-render).
    private func binding(_ index: Int,
                         _ path: ReferenceWritableKeyPath<AssistantViewModel, [Bool]>) -> Binding<Bool> {
        Binding(
            get: { vm[keyPath: path].indices.contains(index) ? vm[keyPath: path][index] : false },
            set: { if vm[keyPath: path].indices.contains(index) { vm[keyPath: path][index] = $0 } })
    }
}

/// One proposed record in the batch card. Deliberately the same shape as the
/// AI-import review row — a reader shouldn't have to learn two layouts for the
/// same decision.
private struct ProposalRow: View {
    let tag: String
    let style: TagChip.Style
    let ticker: String
    let detail: String
    let duplicate: Bool
    let duplicateDate: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            TagChip(text: tag, style: style, width: 46)
            VStack(alignment: .leading, spacing: 1) {
                Text(ticker)
                    .font(Theme.Typo.row)
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if duplicate {
                    Text("Possible duplicate" + (duplicateDate.map { " · \($0.prefix(10))" } ?? ""))
                        .font(Theme.Typo.micro)
                        .foregroundStyle(Theme.loss)
                }
            }
            Spacer(minLength: Theme.Space.s)
            Toggle("", isOn: $isOn).labelsHidden().tint(Theme.accent)
        }
        .padding(.vertical, Theme.Space.s)
    }
}

/// A filled action in the loss colour — the only destructive button in the app.
struct DestructiveButton: View {
    let title: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().tint(.white) }
                else { Text(title).font(Theme.Typo.buttonSm) }
            }
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Theme.loss)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

/// Formatting for proposal payloads.
///
/// Every number on a write card goes through `Fmt`, so a proposed price reads
/// exactly like the same price on the Trades screen — same minus sign, same
/// `US$`, same digits. A card that formats its own numbers is a card that
/// eventually disagrees with the record it is about to write.
enum ProposalFormat {
    /// Changed fields in the order the record form asks for them. Sorting
    /// alphabetically put "Fee" above "Price" on a price correction, which is
    /// the one line the reader came to check.
    private static let fieldOrder = ["type", "ticker", "shares", "price",
                                     "amount", "fee", "date", "market", "notes"]

    static func ordered(_ keys: some Collection<String>) -> [String] {
        keys.sorted { a, b in
            let ia = fieldOrder.firstIndex(of: a) ?? fieldOrder.count
            let ib = fieldOrder.firstIndex(of: b) ?? fieldOrder.count
            return ia == ib ? a < b : ia < ib
        }
    }

    static func label(_ key: String) -> String {
        switch key {
        case "type": return "Side"
        case "ticker": return "Ticker"
        case "shares": return "Shares"
        case "price": return "Price"
        case "amount": return "Amount"
        case "date": return "Date"
        case "fee": return "Fee"
        case "market": return "Market"
        case "notes": return "Notes"
        default: return key.capitalized
        }
    }

    static func value(_ value: JSONValue?, key: String, currency: String) -> String {
        guard let value, let text = value.stringValue, !text.isEmpty else { return "—" }
        switch key {
        case "price":
            return Fmt.number(value.doubleValue, digits: 2)
        case "shares":
            return value.doubleValue.map(Fmt.shares) ?? text
        case "fee", "amount":
            return Fmt.amount(value.doubleValue, currency: currency)
        case "type":
            return text.uppercased()
        case "market":
            return text == "US" ? "US · USD" : "Taiwan · TWD"
        case "date":
            return String(text.prefix(10))
        default:
            return text
        }
    }

    static func tradeDetail(_ row: TradeProposal) -> String {
        let currency = row.displayMarket.currencyCode
        let shares = row.shares ?? row.number("shares") ?? 0
        let price = row.price ?? row.number("price") ?? 0
        let date = String((row.date ?? row.string("date") ?? "").prefix(10))
        var parts = ["\(Fmt.shares(shares)) × \(Fmt.number(price, digits: 2))"]
        if !date.isEmpty { parts.append(date) }
        let fee = row.fee ?? row.number("fee")
        if let fee, fee > 0 { parts.append("fee \(Fmt.amount(fee, currency: currency))") }
        return parts.joined(separator: " · ")
    }

    static func dividendDetail(_ row: DividendProposal) -> String {
        let currency = row.displayMarket.currencyCode
        let amount = row.amount ?? row.number("amount") ?? 0
        let date = String((row.date ?? row.string("date") ?? "").prefix(10))
        var parts = [Fmt.amount(amount, currency: currency)]
        if !date.isEmpty { parts.append(date) }
        return parts.joined(separator: " · ")
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
