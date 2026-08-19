import SwiftUI

/// Dividends across both markets: what has landed, and what is about to.
///
/// The calendar sits above the log deliberately — a dividend you have already
/// received is a record, but one with an ex-date next week is a decision.
struct DividendsView: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var toasts: ToastCenter

    @State private var editing: Dividend?
    /// The record page's subject, held by id so it follows an edit.
    @State private var viewingID: Int?
    @State private var page = 0
    /// Market and year scope, matching the Trades log — the two questions
    /// asked of a dividend record are "which market" and "which tax year".
    @State private var marketFilter: MarketFilter = .all
    @State private var year: String = "All"
    @State private var showAdd = false
    @State private var calendar: DividendCalendar?
    @State private var calendarFailed = false
    @State private var fetchedCalendar = false
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

    private var allDividends: [Dividend] {
        store.dividends.sorted { ($0.payDate, $0.id) > ($1.payDate, $1.id) }
    }

    private var years: [String] {
        ["All"] + Set(allDividends.map { String($0.payDate.prefix(4)) }).sorted(by: >)
    }

    private var dividends: [Dividend] {
        allDividends.filter {
            (marketFilter.market == nil || $0.market == marketFilter.market)
                && (year == "All" || $0.payDate.hasPrefix(year))
        }
    }

    private var pager: Paginator<Dividend> { Paginator(items: dividends, page: page) }

    private var viewing: Dividend? {
        viewingID.flatMap { id in store.dividends.first { $0.id == id } }
    }

    var body: some View {
        if let dividend = viewing {
            DividendRecordView(dividend: dividend,
                               name: store.name(for: dividend.ticker),
                               shares: store.holdings.first { $0.ticker == dividend.ticker }?.shares,
                               onBack: { viewingID = nil },
                               onDelete: {
                                   viewingID = nil
                                   delete(dividend)
                               })
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            list
        }
    }

    /// A dividend row is two lines; fixed so short pages keep their height.
    private static let rowHeight: CGFloat = 58

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                BrandLine()

                ScreenTitle("Dividends") {
                    PrimaryButton(title: "+ Add dividend", fullWidth: false) { showAdd = true }
                }
                .padding(.bottom, 2)

                HStack(spacing: Theme.Space.s) {
                    SegmentedControl(options: MarketFilter.allCases.map { ($0, $0.rawValue) },
                                     selection: $marketFilter, fill: false)
                    Spacer(minLength: Theme.Space.s)
                    if years.count > 1 {
                        SegmentedControl(options: years.map { ($0, $0) },
                                         selection: $year, fill: false, compact: true)
                    }
                }

                statRow

                if let actionError {
                    ErrorBanner(message: actionError) { self.actionError = nil }
                }

                if !upcomingGroups.isEmpty {
                    SectionLabel("Dividend calendar — upcoming")
                        .padding(.top, Theme.Space.xxs)
                    ForEach(upcomingGroups) { group in
                        UpcomingGroupCard(group: group, store: store)
                    }
                }

                HStack {
                    Text("\(dividends.count) records")
                    Spacer()
                    Text(volumeNote)
                }
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, Theme.Space.xxs)

                if dividends.isEmpty {
                    EmptyState(icon: "dollarsign.circle",
                               title: emptyTitle, message: emptyMessage)
                        .appCard()
                } else {
                    let rows = pager.slice
                    Color.clear.frame(height: pager.filler(rowHeight: Self.rowHeight))

                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, div in
                            DividendRow(dividend: div, name: store.name(for: div.ticker))
                                .frame(height: Self.rowHeight)
                                .background(Theme.card)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.22)) { viewingID = div.id }
                                }
                                .contextMenu {
                                    Button("Open record") { viewingID = div.id }
                                    Button("Edit") { editing = div }
                                    Button("Delete", role: .destructive) { delete(div) }
                                }
                            if index < rows.count - 1 { RowDivider() }
                        }
                    }
                    .appListCard()

                    PageBar(page: $page, pageCount: pager.pageCount,
                            rangeLabel: pager.rangeLabel)
                }
            }
            .screenPadding()
        }
        .screenBackground()
        .refreshable { await store.loadAll() }
        .onChange(of: dividends.count) { _, _ in page = min(page, pager.pageCount - 1) }
        .onChange(of: marketFilter) { _, _ in page = 0 }
        .onChange(of: year) { _, _ in page = 0 }
        .task { await loadCalendar() }
        .sheet(isPresented: $showAdd) { DividendFormView(market: .TW, existing: nil) }
        .sheet(item: $editing) { DividendFormView(market: $0.market, existing: $0) }
    }

    // MARK: Stats

    private func received(_ market: MarketCode) -> Double {
        allDividends
            .filter { $0.market == market }
            .filter { year == "All" || $0.payDate.hasPrefix(year) }
            .reduce(0) { $0 + $1.amount }
    }

    /// What is expected to land in the next quarter. The US leg is converted at
    /// the cached FX rate so the figure is one number rather than two; without
    /// a rate it falls back to the TW leg and says so.
    private var next90: (value: Double, currency: String, caption: String) {
        func payments(_ n: Int) -> String { "\(n) payment\(n == 1 ? "" : "s")" }
        let horizon = Calendar.current.date(byAdding: .day, value: 90, to: Date()) ?? Date()
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        iso.timeZone = TimeZone(identifier: "UTC")
        let due = (calendar?.upcoming ?? []).filter {
            guard let d = iso.date(from: String($0.exDate.prefix(10))) else { return false }
            return d <= horizon && d >= Date().addingTimeInterval(-86_400)
        }
        let tw = due.filter { $0.market == .TW }.reduce(0) { $0 + ($1.amount ?? 0) }
        let us = due.filter { $0.market == .US }.reduce(0) { $0 + ($1.amount ?? 0) }
        let fx = DiskCache.load(PortfolioOverview.self, name: "overview")?.fx.usdTwd
        if let fx, fx > 0 {
            return (tw + us * fx, "TWD", payments(due.count))
        }
        return (tw, "TWD", us > 0 ? "TW only · no FX rate" : payments(due.count))
    }

    private var statRow: some View {
        let caption = year == "All" ? "received" : "received in \(year)"
        return HStack(spacing: Theme.Space.s) {
            StatCell(label: "Taiwan",
                     value: Fmt.amount(received(.TW), currency: "TWD"),
                     caption: caption)
            StatCell(label: "US",
                     value: Fmt.amount(received(.US), currency: "USD"),
                     caption: caption)
        }
    }

    struct UpcomingGroup: Identifiable {
        let market: MarketCode
        let rows: [DividendCalendar.Upcoming]
        var id: String { market.rawValue }
        var title: String { market == .TW ? "Taiwan" : "US" }
        var currency: String { market.currencyCode }
        var subtotal: Double { rows.reduce(0) { $0 + ($1.amount ?? 0) } }
        var countLabel: String { "\(rows.count) payment\(rows.count == 1 ? "" : "s")" }
    }

    private var upcomingGroups: [UpcomingGroup] {
        let all = calendar?.upcoming ?? []
        return MarketCode.allCases
            .filter { marketFilter.market == nil || marketFilter.market == $0 }
            .map { market in
                UpcomingGroup(market: market,
                              rows: Array(all.filter { $0.market == market }.prefix(5)))
            }
    }

    private var volumeNote: String {
        let tw = dividends.filter { $0.market == .TW }.count
        return "\(tw) TW · \(dividends.count - tw) US"
    }

    private var emptyTitle: String {
        if allDividends.isEmpty { return "No dividends yet" }
        let scope = marketFilter == .all ? "" : " \(marketFilter.rawValue)"
        return year == "All" ? "No\(scope) dividends match" : "No\(scope) dividends in \(year)"
    }

    private var emptyMessage: String {
        marketFilter == .us && allDividends.allSatisfy({ $0.market != .US })
            ? "Nothing recorded for the US sleeve yet — record a payment, or import a statement."
            : "Record a payment, or import a statement."
    }

    // MARK: Actions

    private func delete(_ div: Dividend) {
        Task {
            do {
                try await APIClient.shared.deleteDividend(div.id)
                toasts.show("Dividend deleted · \(div.ticker)")
            } catch {
                actionError = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
            await store.loadAll()
        }
    }

    /// Stale-while-refresh: show the last saved calendar immediately, then
    /// refresh (the first server-side build sweeps every holding and can take
    /// minutes on a cold backend).
    private func loadCalendar() async {
        if calendar == nil {
            calendar = DiskCache.load(DividendCalendar.self, name: "dividend-calendar")
        }
        guard !fetchedCalendar else { return }
        fetchedCalendar = true
        do {
            let fresh = try await APIClient.shared.getDividendCalendar()
            calendar = fresh
            DiskCache.save(fresh, as: "dividend-calendar")
        } catch {
            fetchedCalendar = false
            if calendar == nil { calendarFailed = true }
        }
    }
}

/// One market's upcoming payments, with its own subtotal.
///
/// Grouped by market rather than listed flat, because the subtotal is the
/// point and there is no honest combined one: TW and US dividends are paid in
/// different currencies, and adding them would need a rate the reader didn't
/// ask about. Recessed onto `inset` so the group reads as a panel of estimates
/// rather than a card of records.
private struct UpcomingGroupCard: View {
    let group: DividendsView.UpcomingGroup
    let store: PortfolioStore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(group.market.rawValue)
                    .eyebrowStyle(Theme.accentChipText, size: 12)
                    .chipFill(Theme.accentTint, radius: 7)
                Text(group.title)
                    .font(Theme.Typo.detailMed)
                    .foregroundStyle(Theme.textStrong)
                Spacer(minLength: Theme.Space.xs)
                Text(Fmt.amount(group.subtotal, currency: group.currency))
                    .font(Theme.Typo.inlineNum)
                    .foregroundStyle(Theme.text)
                    .numeral()
                Text(group.countLabel)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(spacing: 0) {
                if group.rows.isEmpty {
                    Text("No upcoming ex-dividend dates.")
                        .font(Theme.Typo.detail)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.l)
                } else {
                    ForEach(Array(group.rows.enumerated()), id: \.offset) { index, row in
                        UpcomingRow(item: row, name: store.name(for: row.ticker))
                        if index < group.rows.count - 1 {
                            Rectangle().fill(Theme.accentSoft).frame(height: 1)
                                .padding(.leading, Theme.Space.l)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.inset)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(Theme.accentSoft, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }
}

/// One upcoming payment. The date badge is the row's anchor — these rows are
/// scanned by "when", not by "which".
private struct UpcomingRow: View {
    let item: DividendCalendar.Upcoming
    let name: String

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(spacing: 0) {
                Text(day)
                    .font(Theme.Typo.row)
                    .foregroundStyle(Theme.accentChipText)
                Text(month)
                    .font(Theme.Typo.labelSm)
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.accentChipText)
            }
            .frame(width: 42)
            .padding(.vertical, 4)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                TickerLine(ticker: item.ticker, name: name, size: 14.5)
                Text(detail)
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 0) {
                Text(Fmt.amount(item.amount, currency: item.currency))
                    .font(Theme.Typo.row)
                    .foregroundStyle(Theme.text)
                    .numeral()
                Text("est.")
                    .font(Theme.Typo.nano)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, 11)
    }

    private var day: String { String(item.exDate.prefix(10).suffix(2)) }
    private var month: String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let index = (Int(item.exDate.dropFirst(5).prefix(2)) ?? 1) - 1
        return months[min(max(index, 0), 11)]
    }
    private var detail: String {
        var parts = ["Ex-div \(item.exDate.prefix(10))"]
        if let per = item.perShare {
            parts.append("\(Fmt.number(per, digits: 2))/sh")
        }
        return parts.joined(separator: " · ")
    }
}

/// One received payment. The hollow circle is the same glyph a dividend wears
/// on the stock chart, so the two screens agree about what it means.
private struct DividendRow: View {
    let dividend: Dividend
    let name: String

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Circle()
                .stroke(Theme.accent, lineWidth: 1.5)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                TickerLine(ticker: dividend.ticker, name: name, size: 14.5)
                Text(dividend.payDate.prefix(10)
                     + (dividend.notes.map { " · \($0)" } ?? ""))
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(Fmt.amount(dividend.amount, currency: dividend.currency))
                .font(Theme.Typo.row)
                .foregroundStyle(Theme.text)
                .numeral()
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m + 2)
    }
}
