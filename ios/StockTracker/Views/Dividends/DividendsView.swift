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
    @State private var showAdd = false
    @State private var calendar: DividendCalendar?
    @State private var calendarFailed = false
    @State private var fetchedCalendar = false
    @State private var actionError: String?

    private var dividends: [Dividend] {
        store.dividends.sorted { ($0.payDate, $0.id) > ($1.payDate, $1.id) }
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
                    PrimaryButton(title: "+ Add", fullWidth: false) { showAdd = true }
                }
                .padding(.bottom, 2)

                statRow

                if let actionError {
                    ErrorBanner(message: actionError) { self.actionError = nil }
                }

                if !upcoming.isEmpty {
                    SectionLabel("Dividend calendar — upcoming")
                        .padding(.top, Theme.Space.xxs)
                    VStack(spacing: 0) {
                        ForEach(Array(upcoming.enumerated()), id: \.offset) { index, row in
                            UpcomingRow(item: row, name: store.name(for: row.ticker))
                            if index < upcoming.count - 1 { RowDivider() }
                        }
                    }
                    .appListCard()
                }

                SectionLabel("Received · \(dividends.count)")
                    .padding(.top, Theme.Space.xxs)

                if dividends.isEmpty {
                    EmptyState(icon: "dollarsign.circle", title: "No dividends yet",
                               message: "Record a payment, or import a statement.")
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
        .task { await loadCalendar() }
        .sheet(isPresented: $showAdd) { DividendFormView(market: .TW, existing: nil) }
        .sheet(item: $editing) { DividendFormView(market: $0.market, existing: $0) }
    }

    // MARK: Stats

    private func received(_ market: MarketCode) -> Double {
        store.dividends(for: market).reduce(0) { $0 + $1.amount }
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
        HStack(spacing: Theme.Space.s) {
            // Short labels with the qualifier in the caption: three cells
            // across a 390pt screen leaves ~100pt each, and "TAIWAN · RECEIVED"
            // truncated to "TAIWAN · RECE…".
            StatCell(label: "Taiwan",
                     value: Fmt.amount(received(.TW), currency: "TWD"),
                     caption: "received")
            StatCell(label: "US",
                     value: Fmt.amount(received(.US), currency: "USD"),
                     caption: "received")
            StatCell(label: "Next 90 d",
                     value: Fmt.amount(next90.value, currency: next90.currency),
                     caption: next90.caption)
        }
    }

    private var upcoming: [DividendCalendar.Upcoming] {
        Array((calendar?.upcoming ?? []).prefix(5))
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
            .background(Theme.accentTint)
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
