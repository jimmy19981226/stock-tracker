import SwiftUI

struct DividendsView: View {
    let market: MarketCode
    @EnvironmentObject private var store: PortfolioStore
    @State private var editing: Dividend?
    @State private var showAdd = false
    @State private var showImport = false

    private var dividends: [Dividend] {
        store.dividends(for: market).sorted { $0.payDate > $1.payDate }
    }

    private var total: Double { dividends.reduce(0) { $0 + $1.amount } }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if dividends.isEmpty {
                    EmptyState(icon: "dollarsign.circle",
                               title: "No dividends yet",
                               message: "Tap + to record a dividend payment.")
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dividends received")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                        Text(Fmt.money(total, currency: market.currencyCode))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.positive)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 14)
                    ForEach(dividends) { div in
                        DividendRow(dividend: div, name: store.name(for: div.ticker))
                            .onTapGesture { editing = div }
                            .contextMenu {
                                Button("Edit") { editing = div }
                                Button("Delete", role: .destructive) { delete(div) }
                            }
                    }
                }
            }
            .padding(16)
        }
        .refreshable { await store.loadAll() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showImport = true } label: { Image(systemName: "text.viewfinder") }
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showImport) {
            ImportRecordsView()
        }
        .sheet(isPresented: $showAdd) {
            DividendFormView(market: market, existing: nil)
        }
        .sheet(item: $editing) { div in
            DividendFormView(market: market, existing: div)
        }
    }

    private func delete(_ div: Dividend) {
        Task {
            try? await APIClient.shared.deleteDividend(div.id)
            await store.loadAll()
        }
    }
}

private struct DividendRow: View {
    let dividend: Dividend
    let name: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(dividend.ticker)
                        .font(.system(.body, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                    if !name.isEmpty {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    Text(Fmt.prettyDate(dividend.payDate))
                        .font(.caption2)
                        .foregroundStyle(Theme.mutedText)
                }
                Spacer()
                Text("+\(Fmt.money(dividend.amount, currency: dividend.currency))")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(Theme.positive)
            }
            .padding(.vertical, 12)
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
        .contentShape(Rectangle())
    }
}
