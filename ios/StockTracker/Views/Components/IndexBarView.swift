import Charts
import SwiftUI

/// The market-index strip, pinned above the tab bar on the Overview tab.
///
/// Collapsed it is a single scrolling line — the least a market index can be
/// and still be worth glancing at. Expanded it becomes one recessed card per
/// index with the day's range and a month of shape. It lives in the navigation
/// chrome, so it draws no surface of its own beyond the divider that separates
/// it from the tab bar.
struct IndexBarView: View {
    /// `nil` on the Overview root (show everything); a market on a dashboard.
    let market: MarketCode?
    @EnvironmentObject private var store: PortfolioStore
    @State private var showEditor = false
    @State private var expanded = false
    @State private var details: [String: StockDetail] = [:]

    private var indices: [IndexQuote] {
        guard let market else { return store.indices }
        return store.indices.filter { $0.market == market }
    }

    var body: some View {
        if indices.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                if expanded {
                    VStack(spacing: Theme.Space.s) {
                        ForEach(indices) { q in
                            IndexDetailCard(quote: q, detail: details[q.symbol])
                                .task { await loadDetail(q.symbol) }
                        }
                    }
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.top, Theme.Space.m)
                    .padding(.bottom, 2)
                }

                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Space.xl) {
                            ForEach(indices) { q in
                                IndexChip(quote: q)
                            }
                            Button { showEditor = true } label: {
                                Text("＋")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit indices")
                        }
                        .padding(.horizontal, Theme.Space.l)
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textStrong)
                            .frame(width: 36, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Hide index details" : "Show index details")
                }
                .padding(.vertical, 6)
                .padding(.trailing, 4)
            }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            .sheet(isPresented: $showEditor) {
                IndexEditorView().environmentObject(store)
            }
        }
    }

    /// One detail fetch per symbol per screen visit — price and change stay
    /// live from the store; the fetch only feeds the sparkline and O/H/L.
    private func loadDetail(_ symbol: String) async {
        guard details[symbol] == nil else { return }
        if let d = try? await APIClient.shared.getStockDetail(symbol, period: .oneMonth) {
            details[symbol] = d
        }
    }
}

/// One index on the collapsed line: name, level, today's move.
private struct IndexChip: View {
    let quote: IndexQuote

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Text(quote.name)
                .font(Theme.Typo.detailMed)
                .foregroundStyle(Theme.textStrong)
            Text(Fmt.number(quote.price, digits: 2))
                .font(Theme.Typo.inlineNum)
                .foregroundStyle(Theme.text)
                .rollingNumber(quote.price)
            MovePct(pct: quote.changePct)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The expanded card: a recessed `inset` surface — the one place in the app
/// that surface is used, because these sit *inside* the chrome rather than on
/// the ground and a white card here would read as a floating panel.
private struct IndexDetailCard: View {
    let quote: IndexQuote
    let detail: StockDetail?

    private var closes: [(Int, Double)] {
        (detail?.history ?? []).compactMap(\.close).enumerated().map { ($0.offset, $0.element) }
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                    Text(quote.name)
                        .font(Theme.Typo.rowSm)
                        .foregroundStyle(Theme.text)
                    Text(quote.symbol)
                        .font(Theme.Typo.nano)
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(Fmt.number(quote.price, digits: 2))
                    .font(Theme.Typo.value)
                    .foregroundStyle(Theme.text)
                    .numeral()
                    .rollingNumber(quote.price)
                changeLine
                if let live = detail?.live {
                    HStack(spacing: Theme.Space.m) {
                        ohl("O", live.dayOpen)
                        ohl("H", live.dayHigh)
                        ohl("L", live.dayLow)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: Theme.Space.s)

            if closes.count >= 2 {
                Chart(closes, id: \.0) { point in
                    LineMark(x: .value("i", point.0), y: .value("close", point.1))
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .foregroundStyle(Theme.pl(quote.change))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(width: 104, height: 42)
                .overlay(alignment: .topTrailing) {
                    Text("1M")
                        .font(Theme.Typo.axisSm)
                        .foregroundStyle(Theme.textTertiary)
                }
            } else {
                ProgressView().controlSize(.small).frame(width: 104, height: 42)
            }
        }
        .padding(.horizontal, Theme.Space.m + 2)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.inset)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
    }

    @ViewBuilder
    private var changeLine: some View {
        if let change = quote.change {
            HStack(spacing: 4) {
                Text((change >= 0 ? "▲ " : "▼ ") + Fmt.number(abs(change), digits: 2))
                if let pct = quote.changePct {
                    Text("(\(Fmt.number(abs(pct), digits: 2))%)")
                }
            }
            .font(Theme.Typo.captionMed)
            .foregroundStyle(Theme.pl(change))
            .numeral()
            .rollingNumber(change)
        }
    }

    private func ohl(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(Theme.Typo.nano)
                .foregroundStyle(Theme.textTertiary)
            Text(Fmt.number(value, digits: 0))
                .font(Theme.Typo.nano)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Editor sheet: reorder/remove followed indices, add by symbol, or tap a
/// suggestion. Saves to the backend on Done.
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

    private var remaining: [(symbol: String, name: String)] {
        Self.suggestions.filter { !symbols.contains($0.symbol) }
    }

    private func name(for symbol: String) -> String {
        Self.suggestions.first { $0.symbol == symbol }?.name
            ?? store.indices.first { $0.symbol == symbol }?.name
            ?? symbol
    }

    var body: some View {
        SheetScaffold(title: "Market indices", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text("Your indices").statLabelStyle()

                VStack(spacing: 0) {
                    ForEach(Array(symbols.enumerated()), id: \.element) { index, symbol in
                        HStack(spacing: Theme.Space.m) {
                            Text("≡")
                                .font(Theme.Typo.detail)
                                .foregroundStyle(Theme.textTertiary)
                            Text(name(for: symbol))
                                .font(Theme.Typo.detailMed)
                                .foregroundStyle(Theme.text)
                            Spacer(minLength: Theme.Space.s)
                            Text(symbol)
                                .font(Theme.Typo.caption)
                                .foregroundStyle(Theme.textSecondary)
                            Button {
                                symbols.removeAll { $0 == symbol }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 24, height: 24)
                                    .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, Theme.Space.m + 2)
                        .padding(.vertical, Theme.Space.m)
                        if index < symbols.count - 1 { RowDivider(inset: 0) }
                    }
                }
                .appListCard(radius: Theme.Radius.inset)

                LabeledField(label: "Add by symbol") {
                    HStack {
                        TextField("^N225 · 0050.TW", text: $newSymbol)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button("Add") { addNew() }
                            .font(Theme.Typo.detailMed)
                            .foregroundStyle(Theme.accent)
                            .disabled(newSymbol.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if !remaining.isEmpty {
                    Text("Suggestions").statLabelStyle()
                    FlowRow(spacing: Theme.Space.s) {
                        ForEach(remaining, id: \.symbol) { s in
                            SecondaryButton(title: "\(s.name)  \(s.symbol)  ＋") {
                                symbols.append(s.symbol)
                            }
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.Typo.detail)
                        .foregroundStyle(Theme.loss)
                }

                PrimaryButton(title: saving ? "Saving…" : "Done", disabled: saving) { save() }
                    .padding(.top, Theme.Space.xxs)
            }
        }
        .onAppear { symbols = store.indices.map(\.symbol) }
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
