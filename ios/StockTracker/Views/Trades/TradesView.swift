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
            LazyVStack(spacing: 10) {
                if trades.isEmpty {
                    Card { EmptyState(icon: "arrow.left.arrow.right",
                                      title: "No trades yet",
                                      message: "Tap + to log your first buy or sell.") }
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
        Card(padding: 14) {
            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    Image(systemName: isBuy ? "arrow.down" : "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                    Text(isBuy ? "BUY" : "SELL")
                        .font(.system(size: 9, weight: .heavy))
                }
                .foregroundStyle(isBuy ? Theme.positive : Theme.negative)
                .frame(width: 42, height: 42)
                .background((isBuy ? Theme.positive : Theme.negative).opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(trade.ticker)
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
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
                    if trade.status == .closed {
                        Text("CLOSED")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(Theme.mutedText)
                    }
                }
            }
        }
    }
}
