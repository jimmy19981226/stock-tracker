import SwiftUI

/// The trade log for both markets, filtered rather than split — a portfolio
/// held across two exchanges is still one log, and the FIFO cost basis that
/// gives every row its realized P/L is computed over all of it.
struct TradesView: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var toasts: ToastCenter

    @State private var marketFilter: MarketFilter = .all
    @State private var statusFilter: StatusFilter = .all
    @State private var editing: Trade?
    /// The record page's subject, held by id so it follows an edit rather than
    /// showing the snapshot that was tapped.
    @State private var viewingID: Int?
    @State private var page = 0
    @State private var showAdd = false
    @State private var showImport = false
    @State private var actionError: String?

    enum MarketFilter: String, CaseIterable, Identifiable {
        case all = "All", tw = "TW", us = "US"
        var id: String { rawValue }
        var market: MarketCode? {
            switch self {
            case .all: return nil
            case .tw: return .TW
            case .us: return .US
            }
        }
    }

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all = "All", open = "Open", closed = "Closed"
        var id: String { rawValue }
        var status: TradeStatus? {
            switch self {
            case .all: return nil
            case .open: return .open
            case .closed: return .closed
            }
        }
    }

    private var allTrades: [Trade] {
        store.trades.sorted { ($0.tradeDate, $0.id) > ($1.tradeDate, $1.id) }
    }

    private var shown: [Trade] {
        allTrades.filter {
            (marketFilter.market == nil || $0.market == marketFilter.market)
                && (statusFilter.status == nil || $0.status == statusFilter.status)
        }
    }

    private var realized: [Int: Double] { FIFO.realized(store.trades) }

    private var pager: Paginator<Trade> { Paginator(items: shown, page: page) }

    private var viewing: Trade? {
        viewingID.flatMap { id in store.trades.first { $0.id == id } }
    }

    var body: some View {
        if let trade = viewing {
            TradeRecordView(trade: trade,
                            realized: realized[trade.id],
                            name: store.name(for: trade.ticker),
                            onBack: { viewingID = nil },
                            onDelete: {
                                viewingID = nil
                                delete(trade)
                            })
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            list
        }
    }

    /// Every trade row is this tall, so a page of eight looks like a page of
    /// twelve minus four blanks — and the pager under it doesn't move.
    private static let rowHeight: CGFloat = 74

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    BrandLine()
                    Spacer()
                    Button { showImport = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "text.viewfinder")
                                .font(.system(size: 12, weight: .medium))
                            Text("AI import").font(Theme.Typo.detail)
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, Theme.Space.xs)
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }

                ScreenTitle("Trades") {
                    PrimaryButton(title: "+ Add trade", fullWidth: false) { showAdd = true }
                }
                .padding(.bottom, 2)

                HStack(spacing: Theme.Space.s) {
                    SegmentedControl(options: MarketFilter.allCases.map { ($0, $0.rawValue) },
                                     selection: $marketFilter, fill: false)
                    Spacer(minLength: Theme.Space.s)
                    SegmentedControl(options: StatusFilter.allCases.map { ($0, $0.rawValue) },
                                     selection: $statusFilter, fill: false)
                }

                HStack {
                    Text("\(shown.count) records")
                    Spacer()
                    Text(volumeNote)
                }
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.textSecondary)

                if let actionError {
                    ErrorBanner(message: actionError) { self.actionError = nil }
                }

                let rows = pager.slice

                if shown.isEmpty {
                    EmptyState(icon: "arrow.left.arrow.right",
                               title: allTrades.isEmpty ? "No trades yet" : "No trades match",
                               message: allTrades.isEmpty
                                   ? "Add your first buy or sell — or import a brokerage statement."
                                   : "Try a different market or status filter.")
                        .appCard()
                } else {
                    Color.clear.frame(height: pager.filler(rowHeight: Self.rowHeight))

                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, trade in
                            TradeRow(trade: trade,
                                     name: store.name(for: trade.ticker),
                                     realized: realized[trade.id])
                                .frame(height: Self.rowHeight)
                                .background(Theme.card)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.22)) {
                                        viewingID = trade.id
                                    }
                                }
                                .contextMenu {
                                    Button("Open record") {
                                        viewingID = trade.id
                                    }
                                    Button("Edit") { editing = trade }
                                    Button("Delete", role: .destructive) { delete(trade) }
                                }
                            if index < rows.count - 1 { RowDivider() }
                        }
                    }
                    .appListCard()

                    PageBar(page: $page, pageCount: pager.pageCount,
                            rangeLabel: pager.rangeLabel)
                }

                Text("FIFO cost basis — a sell consumes the oldest lots first; any buy lot with shares left is Open. Realized P/L matches broker reporting.")
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Space.xxs)
            }
            .screenPadding()
        }
        .screenBackground()
        .refreshable { await store.loadAll() }
        .onChange(of: marketFilter) { _, _ in page = 0 }
        .onChange(of: statusFilter) { _, _ in page = 0 }
        .onChange(of: shown.count) { _, _ in page = min(page, pager.pageCount - 1) }
        .sheet(isPresented: $showImport) { ImportRecordsView() }
        .sheet(isPresented: $showAdd) {
            TradeFormView(market: marketFilter.market ?? .TW, existing: nil)
        }
        .sheet(item: $editing) { TradeFormView(market: $0.market, existing: $0) }
        .onAppear {
            let env = ProcessInfo.processInfo.environment
            if env["UITEST_TRADE_FORM"] == "1" { showAdd = true }
            if env["UITEST_IMPORT"] == "1" { showImport = true }
        }
    }

    private var volumeNote: String {
        let buys = shown.filter { $0.type == .buy }.count
        return "\(buys) buys · \(shown.count - buys) sells"
    }

    /// Deletes are immediate and reported by a toast — an "are you sure?" on
    /// every row would be noise on a log the user is actively curating, and
    /// the record is one re-entry away.
    private func delete(_ trade: Trade) {
        Task {
            do {
                try await APIClient.shared.deleteTrade(trade.id)
                toasts.show("Trade deleted · \(trade.ticker)")
            } catch {
                actionError = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
            await store.loadAll()
        }
    }
}

/// One trade: what it was, what it cost, what it booked, and whether the lot
/// is still open.
private struct TradeRow: View {
    let trade: Trade
    let name: String
    let realized: Double?

    private var currency: String { trade.market.currencyCode }
    private var isBuy: Bool { trade.type == .buy }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            TagChip(text: isBuy ? "BUY" : "SELL",
                    style: isBuy ? .accent : .outline, width: 44)

            VStack(alignment: .leading, spacing: 1) {
                TickerLine(ticker: trade.ticker, name: name)
                Text(detail)
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.textSecondary)
                    .numeral(0.85)
                if let realized, !isBuy {
                    Text("Realized \(Fmt.signedAmount(realized, currency: currency))")
                        .font(Theme.Typo.micro)
                        .foregroundStyle(Theme.pl(realized))
                        .numeral(0.85)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 1) {
                Text(trade.tradeDate.prefix(10))
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text(trade.status == .open ? "Open" : "Closed")
                    .font(Theme.Typo.microMed)
                    .foregroundStyle(trade.status == .open ? Theme.accent : Theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m + 2)
    }

    private var detail: String {
        let gross = trade.shares * trade.price
        return "\(Fmt.shares(trade.shares)) × \(Fmt.number(trade.price, digits: 2))"
            + " · fee \(Fmt.number(trade.fee, digits: 0))"
            + " · \(Fmt.amount(gross, currency: currency))"
    }
}
