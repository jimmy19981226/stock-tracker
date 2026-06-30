import SwiftUI

struct DividendsView: View {
    let market: MarketCode
    @EnvironmentObject private var store: PortfolioStore
    @State private var editing: Dividend?
    @State private var showAdd = false
    @State private var showImport = false
    @State private var actionError: String?
    @State private var selectedYear: Int? = nil

    private var allDividends: [Dividend] {
        store.dividends(for: market).sorted { $0.payDate > $1.payDate }
    }

    private var availableYears: [Int] {
        let years = allDividends.compactMap { Int($0.payDate.prefix(4)) }
        return Array(Set(years)).sorted(by: >)
    }

    private var dividends: [Dividend] {
        guard let year = selectedYear else { return allDividends }
        return allDividends.filter { $0.payDate.hasPrefix(String(year)) }
    }

    private var total: Double { dividends.reduce(0) { $0 + $1.amount } }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if dividends.isEmpty {
                    EmptyState(icon: "dollarsign.circle",
                               title: selectedYear != nil ? "No dividends in \(selectedYear!)" : "No dividends yet",
                               message: selectedYear != nil ? "Try a different year or 'All'." : "Tap + to record a dividend payment.")
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedYear != nil ? "Dividends received in \(selectedYear!)" : "Dividends received")
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
            DividendFormView(market: market, existing: nil)
        }
        .sheet(item: $editing) { div in
            DividendFormView(market: market, existing: div)
        }
        .alert("Couldn't delete dividend", isPresented: .constant(actionError != nil)) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private func delete(_ div: Dividend) {
        Task {
            do {
                try await APIClient.shared.deleteDividend(div.id)
            } catch {
                actionError = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
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
