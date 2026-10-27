import Charts
import SwiftUI
import UIKit

/// The rotating ticker below the portfolio heading.
/// Quote values continue to come from PortfolioStore's existing refresh stream.
struct IndexBarView: View {
    let market: MarketCode?
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cursor = 0
    @State private var showDetails = false
    @State private var showEditor = false
    @State private var details: [String: StockDetail] = [:]
    @State private var loadingDetails: Set<String> = []
    @State private var finishedDetails: Set<String> = []

    private var indices: [IndexQuote] {
        guard let market else { return store.indices }
        return store.indices.filter { $0.market == market }
    }
    private var effectiveReduceMotion: Bool {
        reduceMotion || ProcessInfo.processInfo.environment["UITEST_REDUCE_MOTION"] == "1"
    }
    private var effectiveScenePhase: ScenePhase {
        ProcessInfo.processInfo.environment["UITEST_TICKER_INACTIVE"] == "1" ? .inactive : scenePhase
    }
    private var canRotate: Bool {
        // Mirroring can be visible while inactive. Reduce Motion controls the
        // transition, not whether the user receives the next market quote.
        indices.count > 1 && effectiveScenePhase != .background && !showDetails && !showEditor
    }

    var body: some View {
        if !indices.isEmpty {
            let quote = indices[cursor % indices.count]
            HStack(spacing: 0) {
                Button(action: advance) {
                    HStack(spacing: Theme.Space.s) {
                        Text(quote.name)
                            .font(Theme.Typo.captionMed)
                            .foregroundStyle(Theme.textStrong)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .layoutPriority(1)
                        Spacer(minLength: 0)
                        Text(quote.price == nil ? "Unavailable" : Fmt.number(quote.price, digits: 2))
                            .font(Theme.Typo.captionMed)
                            .foregroundStyle(Theme.text)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if let change = quote.changePct { MovePct(pct: change) }
                    }
                    .id(quote.symbol)
                    .transition(.opacity)
                    .padding(.leading, Theme.Space.m)
                    .padding(.trailing, Theme.Space.xs)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(quote.name), \(quote.price == nil ? "Unavailable" : Fmt.number(quote.price, digits: 2)), \(Fmt.pct(quote.changePct))")
                .accessibilityValue(quote.symbol)
                .accessibilityHint(indices.count > 1 ? "Show the next index" : "Current market index")
                .accessibilityIdentifier("marketTicker.next")

                Button { showDetails = true } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show all market indices")
                .accessibilityIdentifier("marketTicker.details")
            }
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: Theme.Radius.button))
            .background(Theme.ground)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .task(id: canRotate) {
                guard canRotate else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(4)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    // VoiceOver users control when the spoken quote changes.
                    if !UIAccessibility.isVoiceOverRunning { advance() }
                }
            }
            .onChange(of: indices.map(\.symbol)) { _, _ in cursor = 0 }
            .sheet(isPresented: $showDetails) {
                SheetScaffold(title: "Market indices", onClose: { showDetails = false }) {
                    VStack(spacing: Theme.Space.m) {
                        ForEach(indices) { quote in
                            IndexDetailCard(quote: quote, detail: details[quote.symbol],
                                            isLoading: !finishedDetails.contains(quote.symbol) || loadingDetails.contains(quote.symbol)) {
                                Task { await loadDetail(quote.symbol, retry: true) }
                            }
                                .task { await loadDetail(quote.symbol) }
                        }
                        SecondaryButton(title: "Edit indices", fullWidth: true) { showEditor = true }
                    }
                }
                .sheet(isPresented: $showEditor) {
                    IndexEditorView().environmentObject(store)
                }
            }
        }
    }

    private func advance() {
        guard indices.count > 1 else { return }
        withAnimation(effectiveReduceMotion ? nil : .easeInOut(duration: 0.25)) {
            cursor = (cursor + 1) % indices.count
        }
    }

    private func loadDetail(_ symbol: String, retry: Bool = false) async {
        guard !loadingDetails.contains(symbol), retry || !finishedDetails.contains(symbol) else { return }
        loadingDetails.insert(symbol)
        defer {
            loadingDetails.remove(symbol)
            if !Task.isCancelled { finishedDetails.insert(symbol) }
        }
        if let detail = try? await APIClient.shared.getStockDetail(symbol, period: .oneMonth) {
            guard !Task.isCancelled else { return }
            details[symbol] = detail
        }
    }
}

/// The expanded card: a recessed `inset` surface — the one place in the app
/// that surface is used, because these sit *inside* the chrome rather than on
/// the ground and a white card here would read as a floating panel.
private struct IndexDetailCard: View {
    let quote: IndexQuote
    let detail: StockDetail?
    let isLoading: Bool
    let retry: () -> Void

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
                Text(quote.price == nil ? "Unavailable" : Fmt.number(quote.price, digits: 2))
                    .font(Theme.Typo.value)
                    .foregroundStyle(Theme.text)
                    .numeral()
                    .rollingNumber(quote.price)
                changeLine
                if let source = quote.source, let asOf = quote.asOf {
                    Text("\(source) · \(asOf)")
                        .font(Theme.Typo.nano)
                        .foregroundStyle(Theme.textSecondary)
                }
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

            // The span label sits *above* the sparkline, not over it. As an
            // overlay it collided with the curve whenever the last month
            // trended up — which, on an index, is most months.
            VStack(alignment: .trailing, spacing: 2) {
                Text("1M")
                    .font(Theme.Typo.axisSm)
                    .foregroundStyle(Theme.textTertiary)
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
                    .frame(width: 104, height: 38)
                    .accessibilityIdentifier("index.chart.\(quote.symbol)")
                } else if isLoading {
                    ProgressView().controlSize(.small).frame(width: 104, height: 38)
                        .accessibilityIdentifier("index.loading.\(quote.symbol)")
                } else {
                    VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                        Text("Chart unavailable")
                            .font(Theme.Typo.micro).foregroundStyle(Theme.textSecondary)
                        Button("Retry", action: retry)
                            .font(Theme.Typo.captionMed).foregroundStyle(Theme.accent)
                            .frame(minHeight: Theme.Assistant.control)
                            .accessibilityIdentifier("index.retry.\(quote.symbol)")
                    }
                }
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
