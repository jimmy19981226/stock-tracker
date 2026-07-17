import SwiftUI
import Charts

/// Market-index strip pinned to the bottom of a market's pages — it stays
/// visible while switching between Dashboard / Trades / Dividends, like the
/// index footer in broker apps. Shows only the page's own market's indices
/// (TW page → 加權指數…, US page → S&P 500…).
///
/// Interactions:
///   • chevron (⌃) — expands the strip into detail cards with a 1-month mini
///     chart and the day's open/high/low per index
///   • tap an index (strip or card) — pushes the full detail page (same page
///     as an individual stock)
///   • ＋ — editor sheet to add/reorder/delete followed indices
struct IndexBarView: View {
    let market: MarketCode
    @EnvironmentObject private var store: PortfolioStore
    @State private var showEditor = false
    @State private var expanded = false
    @State private var details: [String: StockDetail] = [:]

    private var indices: [IndexQuote] {
        store.indices.filter { $0.market == market }
    }

    var body: some View {
        if indices.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                Rectangle().fill(Theme.stroke).frame(height: 1)

                if expanded {
                    // Fixed (non-scrolling) panel — every card fully visible.
                    VStack(spacing: 10) {
                        ForEach(indices) { q in
                            NavigationLink(value: q) {
                                IndexDetailCard(quote: q, detail: details[q.symbol])
                            }
                            .buttonStyle(.plain)
                            .task { await loadDetail(q.symbol) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }

                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(indices) { q in
                                NavigationLink(value: q) { IndexChip(quote: q) }
                                    .buttonStyle(.plain)
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
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 40, height: 30)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(expanded ? "Hide index details" : "Show index details")
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

    /// One detail fetch per symbol per screen visit — the price/change in the
    /// card stay live from the store; the fetch only feeds the chart + O/H/L.
    private func loadDetail(_ symbol: String) async {
        guard details[symbol] == nil else { return }
        if let d = try? await APIClient.shared.getStockDetail(symbol, period: .oneMonth) {
            details[symbol] = d
        }
    }
}

/// One index in the slim strip: name, level, and today's move (▲/▼, colored).
private struct IndexChip: View {
    let quote: IndexQuote

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
            ChangeLabel(change: quote.change, changePct: quote.changePct, size: .caption2)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Expanded card: big price + change, day open/high/low, and a 1-month
/// closing-price mini chart. Tapping it opens the full detail page.
private struct IndexDetailCard: View {
    let quote: IndexQuote
    let detail: StockDetail?

    private var closes: [(Int, Double)] {
        (detail?.history ?? [])
            .compactMap(\.close)
            .enumerated()
            .map { ($0.offset, $0.element) }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(quote.name)
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                    Text(quote.symbol)
                        .font(.caption2)
                        .foregroundStyle(Theme.mutedText)
                }
                // Price and change stacked on separate single lines — a long
                // index level must never wrap mid-number.
                Text(Fmt.number(quote.price, digits: 2))
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: quote.price)
                ChangeLabel(change: quote.change, changePct: quote.changePct, size: .caption)
                if let live = detail?.live {
                    HStack(spacing: 10) {
                        ohl("O", live.dayOpen)
                        ohl("H", live.dayHigh)
                        ohl("L", live.dayLow)
                    }
                }
            }
            Spacer(minLength: 8)

            if closes.count >= 2 {
                Chart(closes, id: \.0) { point in
                    LineMark(x: .value("i", point.0), y: .value("close", point.1))
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                        .foregroundStyle(Theme.pl(quote.change))
                        .interpolationMethod(.catmullRom)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(width: 116, height: 46)
                .overlay(alignment: .topTrailing) {
                    Text("1M")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.mutedText)
                        .offset(y: -2)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 116, height: 46)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.mutedText)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardElevated.opacity(0.85))
        )
    }

    private func ohl(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.mutedText)
            Text(Fmt.number(value, digits: 0))
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

/// ▲/▼ + change + (pct), colored like the rest of the app's P&L.
private struct ChangeLabel: View {
    let change: Double?
    let changePct: Double?
    var size: Font.TextStyle = .caption2

    var body: some View {
        if let change {
            HStack(spacing: 2) {
                Image(systemName: change >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 8, weight: .bold))
                Text(Fmt.number(abs(change), digits: 2))
                    .font(.system(size, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                if let changePct {
                    Text("(\(Fmt.number(abs(changePct), digits: 2))%)")
                        .font(.system(size, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(Theme.pl(change))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.25), value: change)
        }
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
