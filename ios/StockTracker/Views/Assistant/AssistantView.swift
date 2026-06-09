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
                        ChatBubble(message: ChatMessage(role: "assistant",
                                   content: vm.streamingText.isEmpty ? "…" : vm.streamingText))
                            .id("streaming")
                    }
                    if let error = vm.error {
                        ErrorBanner(message: error)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
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
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Theme.cardElevated)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .submitLabel(.send)
                .onSubmit { vm.send() }

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

private struct ChatBubble: View {
    let message: ChatMessage
    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(message.content)
                .font(.subheadline)
                .foregroundStyle(isUser ? .white : Theme.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isUser ? Theme.accent : Theme.cardElevated)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .textSelection(.enabled)
            if !isUser { Spacer(minLength: 40) }
        }
    }
}
