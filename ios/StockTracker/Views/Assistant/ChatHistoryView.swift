import SwiftUI

/// Past AI conversations — tap to reopen, swipe to delete, or clear them all.
struct ChatHistoryView: View {
    @ObservedObject var vm: AssistantViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClearAll = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backgroundGradient.ignoresSafeArea()

                if vm.loadingChats && vm.chats.isEmpty {
                    ProgressView()
                } else if vm.chats.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(vm.chats) { chat in
                            Button {
                                Task { await vm.openChat(chat.id); dismiss() }
                            } label: {
                                row(chat)
                            }
                            .listRowBackground(Theme.card)
                            .listRowSeparatorTint(Theme.stroke)
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
        .presentationBackground(Theme.bg)
        .presentationDragIndicator(.visible)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 84, height: 84)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.accent)
            }
            VStack(spacing: 6) {
                Text("No conversations yet")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(Theme.primaryText)
                Text("Ask the Assistant anything about your\nportfolio and it will be saved here.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            Button {
                dismiss()
            } label: {
                Text("Start a chat")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(Theme.accent)
                    .clipShape(Capsule())
            }
            .padding(.top, 4)
        }
        .padding(.bottom, 40)  // optically center against the nav bar
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
