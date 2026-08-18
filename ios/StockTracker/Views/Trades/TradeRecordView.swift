import SwiftUI

/// One trade, on its own page.
///
/// The log row is a summary; this is the record. It answers the questions a row
/// can't fit — what the lot actually cost once the fee is in, what a sell
/// booked under FIFO and against which lots, what was written in the notes —
/// and it is where editing and deleting live, so a tap on a row can no longer
/// drop the user straight into an edit form they didn't ask for.
struct TradeRecordView: View {
    let trade: Trade
    /// Realized P/L this trade booked, FIFO-matched over the whole log.
    let realized: Double?
    let name: String
    let onBack: () -> Void
    let onDelete: () -> Void

    @EnvironmentObject private var store: PortfolioStore
    @State private var editing = false
    @State private var confirmDelete = false

    private var currency: String { trade.market.currencyCode }
    private var isBuy: Bool { trade.type == .buy }
    private var gross: Double { trade.shares * trade.price }
    /// What actually left (buy) or reached (sell) the account.
    private var net: Double { isBuy ? gross + trade.fee : gross - trade.fee }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
                header
                summary
                detailCard
                if let notes = trade.notes, !notes.isEmpty { notesCard(notes) }
                lotCard
                actions
            }
            .screenPadding(bottom: 24)
        }
        .screenBackground()
        .sheet(isPresented: $editing) {
            TradeFormView(market: trade.market, existing: trade)
        }
        .confirmationDialog("Delete this trade?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(isBuy ? "Buy" : "Sell") \(Fmt.shares(trade.shares)) \(trade.ticker) on \(trade.tradeDate.prefix(10)). Deleting it recomputes every FIFO lot after it.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack {
                BackRow(title: "Trades", action: onBack)
                Spacer(minLength: Theme.Space.s)
                TagChip(text: isBuy ? "BUY" : "SELL", style: isBuy ? .accent : .outline)
                TagChip(text: trade.status == .open ? "OPEN" : "CLOSED", style: .neutral)
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(trade.ticker)
                    .font(Theme.Typo.title)
                    .foregroundStyle(Theme.text)
                    .numeral(0.7)
                if !name.isEmpty && name != trade.ticker {
                    Text(name)
                        .font(Theme.Typo.body)
                        .foregroundStyle(Theme.textStrong)
                        .lineLimit(1)
                }
            }
            .padding(.top, Theme.Space.xxs)
        }
    }

    /// The one figure this record is about, and the sentence that explains it.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Fmt.amount(net, currency: currency))
                .font(Theme.Typo.display)
                .foregroundStyle(Theme.text)
                .numeral(0.5)
            Text("\(isBuy ? "Paid for" : "Received from") \(Fmt.shares(trade.shares)) × \(Fmt.number(trade.price, digits: 2)) on \(trade.tradeDate.prefix(10))")
                .font(Theme.Typo.detail)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Cards

    private var detailCard: some View {
        VStack(spacing: 0) {
            row("Market", trade.market == .TW ? "Taiwan · TWD" : "US · USD")
            RowDivider(inset: 0)
            row("Trade date", String(trade.tradeDate.prefix(10)))
            RowDivider(inset: 0)
            row("Shares", Fmt.shares(trade.shares))
            RowDivider(inset: 0)
            row("Price", Fmt.number(trade.price, digits: 2))
            RowDivider(inset: 0)
            row("Fee", Fmt.amount(trade.fee, currency: currency))
            RowDivider(inset: 0)
            row("Gross", Fmt.amount(gross, currency: currency))
            RowDivider(inset: 0)
            row(isBuy ? "Total cost" : "Net proceeds", Fmt.amount(net, currency: currency))
            if let realized, !isBuy {
                RowDivider(inset: 0)
                KeyValueRow("Realized P/L") {
                    PLValue(value: realized, currency: currency, font: Theme.Typo.inlineNum)
                }
                .padding(.vertical, 7)
            }
        }
        .appCard()
    }

    private func notesCard(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Notes").statLabelStyle()
            Text(notes)
                .font(Theme.Typo.body)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .appCard()
    }

    /// Why this row says Open or Closed. The status is derived, not entered,
    /// and that surprises people often enough to be worth one sentence.
    private var lotCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(isBuy ? "This lot" : "FIFO match").statLabelStyle()
            Text(explanation)
                .font(Theme.Typo.detail)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .appCard()
    }

    private var explanation: String {
        if isBuy {
            return trade.status == .open
                ? "Still open — some or all of these shares have not been sold, so their cost stays in the position's basis."
                : "Fully consumed by later sells. Its cost has already been booked into realized P/L."
        }
        return "Matched against the oldest open lots first. Realized P/L is the proceeds after this sell's fee, less the cost of the lots it consumed (buy fees included)."
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.s) {
            PrimaryButton(title: "Edit trade") { editing = true }
            SecondaryButton(title: "Delete") { confirmDelete = true }
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        KeyValueRow(key, value).padding(.vertical, 7)
    }
}
