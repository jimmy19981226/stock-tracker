import SwiftUI

@MainActor
final class AssistantViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var streamingText = ""
    @Published var isStreaming = false
    @Published var input = ""
    @Published var status: AiStatus?
    @Published var error: String?

    private var chatId: Int?

    init() {
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
        messages.append(ChatMessage(role: "user", content: text))
        isStreaming = true
        streamingText = ""

        Task {
            do {
                try await APIClient.shared.streamChat(
                    chatId: chatId,
                    message: text,
                    onInit: { [weak self] id, _ in self?.chatId = id },
                    onChunk: { [weak self] delta in self?.streamingText += delta },
                    onDone: { [weak self] content, _ in
                        guard let self else { return }
                        let final = content.isEmpty ? self.streamingText : content
                        self.messages.append(ChatMessage(role: "assistant", content: final))
                        self.streamingText = ""
                    }
                )
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
                if !streamingText.isEmpty {
                    messages.append(ChatMessage(role: "assistant", content: streamingText))
                    streamingText = ""
                }
            }
            isStreaming = false
        }
    }

    func reset() {
        chatId = nil
        messages = []
        streamingText = ""
        error = nil
    }
}

/// The AI assistant chat — a native iMessage-style transcript with a streamed
/// reply bubble, backed by the same /api/ai/chat SSE endpoint as the web app.
struct AssistantView: View {
    @StateObject private var vm = AssistantViewModel()
    @State private var showSettings = false
    @State private var providerHasKey = AISettings.hasKey(for: AISettings.activeProvider)
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if !providerHasKey {
                noKeyBanner
            }
            inputBar
        }
        .screenBackground()
        .navigationTitle("Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task { await vm.loadStatus() }
        .onAppear { providerHasKey = AISettings.hasKey(for: AISettings.activeProvider) }
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
                    ForEach(Array(vm.messages.enumerated()), id: \.offset) { _, msg in
                        ChatBubble(message: msg)
                    }
                    if vm.isStreaming {
                        Group {
                            if vm.streamingText.isEmpty {
                                TypingIndicator()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                ChatBubble(message: ChatMessage(role: "assistant",
                                                                content: vm.streamingText))
                            }
                        }
                        .id("streaming")
                    }
                    if let error = vm.error {
                        ErrorBanner(message: error)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            // Swipe down on the transcript to dismiss the keyboard.
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vm.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: vm.streamingText) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("Ask about your portfolio")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
            Text("“How is my Taiwan portfolio doing?”\n“What's my best performing stock?”")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Message", text: $vm.input, axis: .vertical)
                .focused($inputFocused)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Theme.cardElevated)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Button { vm.send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(vm.canSend ? Theme.accent : Theme.mutedText)
            }
            .disabled(!vm.canSend)
        }
        .padding(12)
        .background(Theme.card)
    }
}

/// Three dots bouncing in sequence while the assistant is "thinking".
private struct TypingIndicator: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    let wave = sin(t * 6 + Double(i) * 0.7)
                    Circle()
                        .fill(Theme.secondaryText)
                        .frame(width: 8, height: 8)
                        .offset(y: -CGFloat(max(0, wave)) * 5)
                        .opacity(0.5 + 0.5 * max(0, wave))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.cardElevated)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
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
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
        } else {
            // Assistant replies render as full-width formatted Markdown, like Claude.
            MarkdownText(markdown: content)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Strip the internal `<!--meta:{...}-->` header the backend prepends to the
    /// canonical reply (the web app hides it too).
    static func stripMeta(_ s: String) -> String {
        var out = s
        if out.hasPrefix("<!--meta:"), let r = out.range(of: "-->") {
            out = String(out[r.upperBound...])
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
