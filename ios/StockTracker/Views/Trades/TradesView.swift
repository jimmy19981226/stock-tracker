import SwiftUI

struct TradesView: View {
    let market: MarketCode
    @EnvironmentObject private var store: PortfolioStore
    @State private var editing: Trade?
    @State private var showAdd = false

    private var trades: [Trade] {
        store.trades(for: market).sorted { $0.tradeDate > $1.tradeDate }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if trades.isEmpty {
                    EmptyState(icon: "arrow.left.arrow.right",
                               title: "No trades yet",
                               message: "Tap + to log your first buy or sell.")
                } else {
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
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) {
            TradeFormView(market: market, existing: nil)
        }
        .sheet(item: $editing) { trade in
            TradeFormView(market: market, existing: trade)
        }
    }

    private func delete(_ trade: Trade) {
        Task {
            try? await APIClient.shared.deleteTrade(trade.id)
            await store.loadAll()
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
