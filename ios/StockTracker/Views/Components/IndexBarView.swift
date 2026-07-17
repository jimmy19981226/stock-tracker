import SwiftUI

/// Slim market-index strip pinned to the bottom of a market's pages — it stays
/// visible while switching between Dashboard / Trades / Dividends, like the
/// index footer in broker apps. Shows every index the user follows (default:
/// 加權指數 + S&P 500) and scrolls horizontally when they add more. US indices
/// tick in real time via the quote stream; the ⌃/⌄ chevron collapses the bar.
struct IndexBarView: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var showEditor = false
    @State private var collapsed = false

    var body: some View {
        if store.indices.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                Rectangle().fill(Theme.stroke).frame(height: 1)
                HStack(spacing: 0) {
                    if collapsed {
                        // Collapsed: one line summarizing the first index.
                        if let first = store.indices.first {
                            IndexChip(quote: first, compact: true)
                                .padding(.leading, 16)
                        }
                        Spacer()
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 18) {
                                ForEach(store.indices) { q in
                                    IndexChip(quote: q, compact: false)
                                }
                                Button {
                                    showEditor = true
                                } label: {
                                    Image(systemName: "plus.circle")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Theme.mutedText)
                                }
                                .accessibilityLabel("Edit indices")
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { collapsed.toggle() }
                    } label: {
                        Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 40, height: 30)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(collapsed ? "Expand index bar" : "Collapse index bar")
                }
                .padding(.vertical, 7)
            }
            .background(Theme.card.opacity(0.92))
            .sheet(isPresented: $showEditor) {
                IndexEditorView()
                    .environmentObject(store)
            }
        }
    }
}

/// One index in the strip: name, level, and today's move (▲/▼, colored).
private struct IndexChip: View {
    let quote: IndexQuote
    let compact: Bool

    private var changeColor: Color { Theme.pl(quote.change) }

    var body: some View {
        HStack(spacing: 8) {
            Text(quote.name)
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Text(Fmt.number(quote.price, digits: 2))
                .font(.system(.footnote, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Theme.primaryText)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.25), value: quote.price)
            if let change = quote.change {
                HStack(spacing: 2) {
                    Image(systemName: change >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text(Fmt.number(abs(change), digits: 2))
                        .font(.system(.caption2, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    if let pct = quote.changePct {
                        Text("(\(Fmt.number(abs(pct), digits: 2))%)")
                            .font(.system(.caption2, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(changeColor)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.25), value: change)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Editor sheet: reorder/delete followed indices, add by symbol, or tap a
/// common suggestion. Saves to the backend on Done.
struct IndexEditorView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    @State private var symbols: [String] = []
    @State private var newSymbol = ""
    @State private var saving = false
    @State private var errorMessage: String?

    /// Common indices worth suggesting (mirrors the backend's known names).
    private static let suggestions: [(symbol: String, name: String)] = [
        ("^TWII", "加權指數"),
        ("^TWOII", "櫃買指數"),
        ("^GSPC", "S&P 500"),
        ("^IXIC", "NASDAQ"),
        ("^DJI", "Dow Jones"),
        ("^SOX", "費城半導體"),
        ("^VIX", "VIX"),
        ("^N225", "日經 225"),
        ("^HSI", "恒生指數"),
    ]

    private var remainingSuggestions: [(symbol: String, name: String)] {
        Self.suggestions.filter { !symbols.contains($0.symbol) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Your indices") {
                    ForEach(symbols, id: \.self) { s in
                        HStack {
                            Text(Self.suggestions.first { $0.symbol == s }?.name
                                 ?? store.indices.first { $0.symbol == s }?.name
                                 ?? s)
                            Spacer()
                            Text(s).foregroundStyle(.secondary).font(.footnote)
                        }
                    }
                    .onDelete { symbols.remove(atOffsets: $0) }
                    .onMove { symbols.move(fromOffsets: $0, toOffset: $1) }
                }

                Section("Add by symbol") {
                    HStack {
                        TextField("Yahoo symbol, e.g. ^N225 or 0050.TW", text: $newSymbol)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button("Add") { addNew() }
                            .disabled(newSymbol.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if !remainingSuggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(remainingSuggestions, id: \.symbol) { s in
                            Button {
                                symbols.append(s.symbol)
                            } label: {
                                HStack {
                                    Text(s.name).foregroundStyle(Theme.primaryText)
                                    Spacer()
                                    Text(s.symbol).foregroundStyle(.secondary).font(.footnote)
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(Theme.negative) }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Market indices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Done") { save() }
                        .disabled(saving)
                }
            }
            .onAppear { symbols = store.indices.map(\.symbol) }
        }
    }

    private func addNew() {
        let s = newSymbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !s.isEmpty else { return }
        if !symbols.contains(s) { symbols.append(s) }
        newSymbol = ""
    }

    private func save() {
        saving = true
        errorMessage = nil
        Task {
            do {
                try await APIClient.shared.setIndices(symbols)
                await store.refreshIndices()
                dismiss()
            } catch {
                errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
            saving = false
        }
    }
}
