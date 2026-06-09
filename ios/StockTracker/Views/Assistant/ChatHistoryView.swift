import SwiftUI

/// Past AI conversations — tap to reopen, swipe to delete, or clear them all.
struct ChatHistoryView: View {
    @ObservedObject var vm: AssistantViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClearAll = false

    var body: some View {
        NavigationStack {
            Group {
                if vm.loadingChats && vm.chats.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.chats.isEmpty {
                    EmptyState(icon: "bubble.left.and.bubble.right",
                               title: "No conversations yet",
                               message: "Your AI chats will show up here.")
                } else {
                    List {
                        ForEach(vm.chats) { chat in
                            Button {
                                Task { await vm.openChat(chat.id); dismiss() }
                            } label: {
                                row(chat)
                            }
                            .listRowBackground(Theme.card)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await vm.deleteChat(chat.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Chat History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        confirmClearAll = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(vm.chats.isEmpty)
                }
            }
            .confirmationDialog("Delete all conversations?",
                                isPresented: $confirmClearAll, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    Task { await vm.deleteAllChats() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes every saved AI conversation.")
            }
            .task { await vm.loadChats() }
        }
    }

    private func row(_ chat: ChatSummary) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(chat.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(chat.messageCount) message\(chat.messageCount == 1 ? "" : "s")")
                    Text("·")
                    Text(Fmt.prettyDate(chat.updatedAt))
                }
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if vm.currentChatId == chat.id {
                Text("OPEN")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Theme.accent)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.mutedText)
        }
        .contentShape(Rectangle())
    }
}
