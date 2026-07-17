import SwiftUI
import Charts

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
                IncomeCalendarCard(market: market)
                    .padding(.bottom, 16)
                if dividends.isEmpty {
                    EmptyState(icon: "dollarsign.circle",
                               title: selectedYear != nil ? "No dividends in \(selectedYear!)" : "No dividends yet",
                               message: selectedYear != nil ? "Try a different year or 'All'." : "Tap + to record a dividend payment.")
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        // String(year) — interpolating the Int directly makes Text
                        // localize it with a thousands comma ("2,026").
                        Text(selectedYear != nil ? "Dividends received in \(String(selectedYear!))" : "Dividends received")
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

// MARK: - Income calendar (除權息行事曆 + projected income)

/// Card at the top of the Dividends tab: projected annual dividend income for
/// this market, a 12-month bar chart of expected payments (each holding's
/// trailing payout schedule projected forward), and known upcoming ex-dividend
/// dates. Hides itself if the backend doesn't have /api/dividends/calendar.
private struct IncomeCalendarCard: View {
    let market: MarketCode
    @EnvironmentObject private var store: PortfolioStore
    @State private var calendar: DividendCalendar?
    @State private var failed = false

    private var currency: String { market.currencyCode }

    private var projected: Double? {
        calendar?.projectedAnnual.first { $0.currency == currency }?.amount
    }

    /// (month label, expected amount in this market's currency)
    private var monthTotals: [(String, Double)] {
        (calendar?.months ?? []).map { m in
            (String(m.month.suffix(2)),
             m.totals.first { $0.currency == currency }?.amount ?? 0)
        }
    }

    private var upcoming: [DividendCalendar.Upcoming] {
        (calendar?.upcoming ?? []).filter { $0.market == market }.prefix(4).map { $0 }
    }

    var body: some View {
        if failed || (calendar != nil && projected == nil && upcoming.isEmpty) {
            EmptyView()
        } else {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Income calendar")
                        .font(.headline)
                        .foregroundStyle(Theme.primaryText)

                    if let calendar {
                        if let projected {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Projected annual income")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.mutedText)
                                Text(Fmt.money(projected, currency: currency, digits: 0))
                                    .font(.system(size: 26, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.positive)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                        }

                        if monthTotals.contains(where: { $0.1 > 0 }) {
                            Chart(monthTotals, id: \.0) { m in
                                BarMark(x: .value("Month", m.0), y: .value("Amount", m.1))
                                    .foregroundStyle(Theme.positive.opacity(0.75))
                                    .cornerRadius(3)
                            }
                            .chartYAxis {
                                AxisMarks(position: .trailing) { v in
                                    AxisGridLine().foregroundStyle(Theme.stroke)
                                    AxisValueLabel {
                                        if let d = v.as(Double.self) {
                                            Text(Fmt.compact(d))
                                                .font(.system(size: 9))
                                                .foregroundStyle(Theme.mutedText)
                                        }
                                    }
                                }
                            }
                            .chartXAxis {
                                AxisMarks { v in
                                    AxisValueLabel {
                                        if let s = v.as(String.self) {
                                            Text(s)
                                                .font(.system(size: 9))
                                                .foregroundStyle(Theme.mutedText)
                                        }
                                    }
                                }
                            }
                            .frame(height: 110)
                        }

                        if !upcoming.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Upcoming ex-dividend dates")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.mutedText)
                                ForEach(upcoming, id: \.self) { u in
                                    HStack {
                                        Text(u.ticker)
                                            .font(.system(.footnote, design: .rounded).weight(.bold))
                                            .foregroundStyle(Theme.primaryText)
                                        Text(store.name(for: u.ticker))
                                            .font(.caption2)
                                            .foregroundStyle(Theme.mutedText)
                                            .lineLimit(1)
                                        Spacer()
                                        if let amount = u.amount {
                                            Text("≈\(Fmt.money(amount, currency: u.currency, digits: 0))")
                                                .font(.system(.footnote, design: .rounded).weight(.semibold))
                                                .monospacedDigit()
                                                .foregroundStyle(Theme.positive)
                                        }
                                        Text(Fmt.prettyDate(u.exDate))
                                            .font(.caption2)
                                            .monospacedDigit()
                                            .foregroundStyle(Theme.secondaryText)
                                    }
                                }
                            }
                        }
                    } else {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Building income projection…")
                                .font(.footnote)
                                .foregroundStyle(Theme.mutedText)
                        }
                    }
                }
            }
            .task { await load() }
        }
    }

    @State private var fetchedOnce = false

    /// Stale-while-refresh: show the last saved calendar immediately, then
    /// refresh (the first server-side build sweeps yfinance for every holding
    /// and can take minutes on a cold backend).
    private func load() async {
        if calendar == nil {
            calendar = DiskCache.load(DividendCalendar.self, name: "dividend-calendar")
        }
        guard !fetchedOnce else { return }
        fetchedOnce = true
        do {
            let fresh = try await APIClient.shared.getDividendCalendar()
            calendar = fresh
            DiskCache.save(fresh, as: "dividend-calendar")
        } catch {
            // Hide only if there's nothing at all to show; a stale projection
            // beats an empty card. Retry next time the tab appears.
            fetchedOnce = false
            if calendar == nil { failed = true }
        }
    }
}
