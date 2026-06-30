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
                        currency: market.currencyCode,
                        year: selectedYear
                    )
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
                    }
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
    let currency: String
    let year: Int?

    private var net: Double { sells - buys }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(year != nil ? "Summary for \(year!)" : "All-time summary")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bought")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedText)
                    Text(Fmt.money(buys, currency: currency, digits: 0))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.negative)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sold")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedText)
                    Text(Fmt.money(sells, currency: currency, digits: 0))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.positive)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Net cash")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedText)
                    Text((net >= 0 ? "+" : "") + Fmt.money(net, currency: currency, digits: 0))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(net >= 0 ? Theme.positive : Theme.negative)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
