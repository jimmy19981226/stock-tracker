import SwiftUI

/// One dividend, on its own page — the twin of `TradeRecordView`.
///
/// A dividend row is three facts wide; the record is where the rest lives, and
/// where editing and deleting belong so a tap on a row doesn't drop the reader
/// into a form they didn't ask for.
struct DividendRecordView: View {
    let dividend: Dividend
    let name: String
    /// Shares held of this ticker now, for the per-share reading.
    let shares: Double?
    let onBack: () -> Void
    let onDelete: () -> Void

    @State private var editing = false
    @State private var confirmDelete = false

    private var currency: String { dividend.currency }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
                header
                summary
                detailCard
                if let notes = dividend.notes, !notes.isEmpty { notesCard(notes) }
                actions
            }
            .screenPadding(bottom: 24)
        }
        .screenBackground()
        .sheet(isPresented: $editing) {
            DividendFormView(market: dividend.market, existing: dividend)
        }
        .confirmationDialog("Delete this dividend?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(dividend.ticker) · \(Fmt.amount(dividend.amount, currency: currency)) on \(dividend.payDate.prefix(10)).")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack {
                BackRow(title: "Dividends", action: onBack)
                Spacer(minLength: Theme.Space.s)
                TagChip(text: "DIV", style: .neutral)
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(dividend.ticker)
                    .font(Theme.Typo.title)
                    .foregroundStyle(Theme.text)
                    .numeral(0.7)
                if !name.isEmpty && name != dividend.ticker {
                    Text(name)
                        .font(Theme.Typo.body)
                        .foregroundStyle(Theme.textStrong)
                        .lineLimit(1)
                }
            }
            .padding(.top, Theme.Space.xxs)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Fmt.amount(dividend.amount, currency: currency))
                .font(Theme.Typo.display)
                .foregroundStyle(Theme.text)
                .numeral(0.5)
            Text("Paid \(dividend.payDate.prefix(10))")
                .font(Theme.Typo.detail)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var detailCard: some View {
        VStack(spacing: 0) {
            row("Market", dividend.market == .TW ? "Taiwan · TWD" : "US · USD")
            RowDivider(inset: 0)
            row("Pay date", String(dividend.payDate.prefix(10)))
            RowDivider(inset: 0)
            row("Amount", Fmt.amount(dividend.amount, currency: currency))
            // Per-share is derived from *today's* holding, so it's only honest
            // while the position is still open at the same size.
            if let shares, shares > 0 {
                RowDivider(inset: 0)
                row("Per share, at today's \(Fmt.shares(shares)) sh",
                    Fmt.number(dividend.amount / shares, digits: 2))
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

    private var actions: some View {
        HStack(spacing: Theme.Space.s) {
            PrimaryButton(title: "Edit dividend") { editing = true }
            SecondaryButton(title: "Delete") { confirmDelete = true }
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        KeyValueRow(key, value).padding(.vertical, 7)
    }
}
