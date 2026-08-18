import SwiftUI

/// Past conversations — tap to reopen, swipe to delete, or clear them all.
struct ChatHistoryView: View {
    @ObservedObject var vm: AssistantViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClearAll = false

    var body: some View {
        SheetScaffold(title: "Chat history", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    Spacer()
                    SecondaryButton(title: "Clear all") { confirmClearAll = true }
                        .disabled(vm.chats.isEmpty)
                }

                if vm.loadingChats && vm.chats.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                } else if vm.chats.isEmpty {
                    EmptyState(icon: "bubble.left.and.bubble.right",
                               title: "No conversations yet",
                               message: "Ask the assistant anything about your portfolio and it will be saved here.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(vm.chats.enumerated()), id: \.element.id) { index, chat in
                            SwipeToDelete(onDelete: { Task { await vm.deleteChat(chat.id) } }) {
                                Button {
                                    Task { await vm.openChat(chat.id); dismiss() }
                                } label: {
                                    row(chat)
                                }
                                .buttonStyle(.plain)
                            }
                            if index < vm.chats.count - 1 { RowDivider() }
                        }
                    }
                    .appListCard(radius: Theme.Radius.inset)
                }
            }
        }
        .confirmationDialog("Delete all conversations?",
                            isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { Task { await vm.deleteAllChats() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every saved conversation.")
        }
        .task { await vm.loadChats() }
    }

    private func row(_ chat: ChatSummary) -> some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.title)
                    .font(Theme.Typo.detailMed)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text("\(chat.messageCount) message\(chat.messageCount == 1 ? "" : "s") · \(Fmt.prettyDate(chat.updatedAt))")
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Space.s)
            if vm.currentChatId == chat.id {
                TagChip(text: "OPEN", style: .accent)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, Theme.Space.m + 2)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
