import SwiftUI

struct TradesView: View {
    let market: MarketCode
    @EnvironmentObject private var store: PortfolioStore
    @State private var editing: Trade?
    @State private var showAdd = false
    @State private var showImport = false
    @State private var actionError: String?
    @State private var selectedYear: Int? = nil

    private var allTrades: [Trade] {
        store.trades(for: market).sorted { $0.tradeDate > $1.tradeDate }
    }

    private var availableYears: [Int] {
        let years = allTrades.compactMap { Int($0.tradeDate.prefix(4)) }
        return Array(Set(years)).sorted(by: >)
    }

    private var trades: [Trade] {
        guard let year = selectedYear else { return allTrades }
        return allTrades.filter { $0.tradeDate.hasPrefix(String(year)) }
    }

    private var totalBuys: Double {
        trades.filter { $0.type == .buy }
            .reduce(0) { $0 + $1.shares * $1.price + $1.fee }
    }

    private var totalSells: Double {
        trades.filter { $0.type == .sell }
            .reduce(0) { $0 + $1.shares * $1.price - $1.fee }
    }

    /// Realized P/L booked by the filtered trades — FIFO lots with buy fees in
    /// the cost basis and sell fees deducted, mirroring the backend's
    /// _apply_trade so this agrees with the dashboard's Realized figure.
    /// The whole history is always walked (cost basis crosses years); only
    /// sells inside the filter window count toward the total.
    private var totalEarned: Double {
        var lots: [String: [(shares: Double, costPerShare: Double)]] = [:]
        var earned = 0.0
        let yearPrefix = selectedYear.map(String.init)
        for t in allTrades.sorted(by: { ($0.tradeDate, $0.id) < ($1.tradeDate, $1.id) }) {
            if t.type == .buy {
                guard t.shares > 0 else { continue }
                lots[t.ticker, default: []]
                    .append((t.shares, (t.shares * t.price + t.fee) / t.shares))
                continue
            }
            var qty = t.shares
            var delta = -t.fee
            var open = lots[t.ticker] ?? []
            while qty > 1e-9, !open.isEmpty {
                let take = min(qty, open[0].shares)
                delta += take * (t.price - open[0].costPerShare)
                open[0].shares -= take
                qty -= take
                if open[0].shares <= 1e-9 { open.removeFirst() }
            }
            lots[t.ticker] = open
            if qty > 1e-9 { delta += qty * t.price }  // over-sell: no cost basis
            if yearPrefix == nil || t.tradeDate.hasPrefix(yearPrefix!) { earned += delta }
        }
        return earned
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if trades.isEmpty {
                    EmptyState(icon: "arrow.left.arrow.right",
                               title: selectedYear != nil ? "No trades in \(selectedYear!)" : "No trades yet",
                               message: selectedYear != nil ? "Try a different year or 'All'." : "Tap + to log your first buy or sell.")
                } else {
                    TradeSummaryCard(
                        buys: totalBuys,
                        sells: totalSells,
                        earned: totalEarned,
                        currency: market.currencyCode,
                        year: selectedYear
                    )
                    .cardStyle()
                    .padding(.bottom, 14)
                    ForEach(trades) { trade in
                        TradeRow(trade: trade, name: store.name(for: trade.ticker))
                            .onTapGesture { editing = trade }
                            .contextMenu {
                                Button("Edit") { editing = trade }
                                Button("Delete", role: .destructive) { delete(trade) }
                            }
                    }
                }
            }
            .padding(16)
        }
        .refreshable { await store.loadAll() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !availableYears.isEmpty {
                    Menu {
                        Button {
                            selectedYear = nil
                        } label: {
                            HStack {
                                Text("All time")
                                if selectedYear == nil { Image(systemName: "checkmark") }
                            }
                        }
                        ForEach(availableYears, id: \.self) { year in
                            Button {
                                selectedYear = year
                            } label: {
                                HStack {
                                    Text(String(year))
                                    if selectedYear == year { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        Label(selectedYear.map { String($0) } ?? "All", systemImage: "calendar")
                            .font(.system(size: 14, weight: .medium))
                            .fixedSize()
                    }
                    // Same Menu label-sizing quirk as the holdings sort pill:
                    // rebuild when the title changes so it never clips.
                    .id(selectedYear)
                }
                Button { showImport = true } label: { Image(systemName: "text.viewfinder") }
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showImport) {
            ImportRecordsView()
        }
        .sheet(isPresented: $showAdd) {
            TradeFormView(market: market, existing: nil)
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["UITEST_TRADE_FORM"] == "1" { showAdd = true }
            if ProcessInfo.processInfo.environment["UITEST_IMPORT"] == "1" { showImport = true }
        }
        .sheet(item: $editing) { trade in
            TradeFormView(market: market, existing: trade)
        }
        .alert("Couldn't delete trade", isPresented: .constant(actionError != nil)) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private func delete(_ trade: Trade) {
        Task {
            do {
                try await APIClient.shared.deleteTrade(trade.id)
            } catch {
                actionError = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
            await store.loadAll()
        }
    }
}

private struct TradeSummaryCard: View {
    let buys: Double
    let sells: Double
    let earned: Double
    let currency: String
    let year: Int?

    private var net: Double { sells - buys }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // String(year) — a raw Int interpolation gets a locale comma ("2,026").
            Text(year != nil ? "Summary for \(String(year!))" : "All-time summary")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 16) {
                stat("Bought", Fmt.money(buys, currency: currency, digits: 0),
                     color: Theme.negative)
                stat("Sold", Fmt.money(sells, currency: currency, digits: 0),
                     color: Theme.positive)
                stat("Net cash", Fmt.signedMoney(net, currency: currency, digits: 0),
                     color: net >= 0 ? Theme.positive : Theme.negative)
                stat("Earned", Fmt.signedMoney(earned, currency: currency, digits: 0),
                     color: Theme.pl(earned))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.mutedText)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(color)
                .minimumScaleFactor(0.65)
                .lineLimit(1)
        }
    }
}

private struct TradeRow: View {
    let trade: Trade
    let name: String

    private var isBuy: Bool { trade.type == .buy }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(trade.ticker)
                            .font(.system(.body, design: .rounded).weight(.bold))
                            .foregroundStyle(Theme.primaryText)
                        Text(isBuy ? "Buy" : "Sell")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(isBuy ? Theme.positive : Theme.negative)
                        if trade.status == .closed {
                            Text("Closed")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.mutedText)
                        }
                    }
                    if !name.isEmpty {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    Text(Fmt.prettyDate(trade.tradeDate))
                        .font(.caption2)
                        .foregroundStyle(Theme.mutedText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(Fmt.shares(trade.shares)) @ \(Fmt.money(trade.price, currency: trade.market.currencyCode))")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text(Fmt.money(trade.shares * trade.price, currency: trade.market.currencyCode, digits: 0))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.vertical, 12)
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
        .contentShape(Rectangle())
    }
}
