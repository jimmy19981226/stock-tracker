import SwiftUI

/// Add or edit a trade.
struct TradeFormView: View {
    let market: MarketCode
    let existing: Trade?
    /// Pre-fills the ticker when adding from a stock's detail page.
    var prefillTicker: String? = nil

    var body: some View {
        RecordFormSheet(kind: .trade, market: market, prefillTicker: prefillTicker,
                        existingTrade: existing, existingDividend: nil)
    }
}

/// The one add/edit sheet, for both kinds of record.
///
/// **The market is explicit.** Typing a ticker picks it (an all-digit code is
/// TWSE/TPEx, letters are US, a ticker you already hold matches by name) and a
/// hint line says what was matched — but the control is always there and always
/// overridable. That pick drives the currency labels, the automatic fee and the
/// validation, so a lettered symbol filed under Taiwan is rejected with a
/// specific message rather than silently guessed into the wrong market.
struct RecordFormSheet: View {
    enum Kind { case trade, dividend }

    let kind: Kind
    let market: MarketCode
    var prefillTicker: String?
    var existingTrade: Trade?
    var existingDividend: Dividend?

    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    @State private var type: TradeType = .buy
    @State private var selectedMarket: MarketCode?
    @State private var ticker = ""
    @State private var shares = ""
    @State private var price = ""
    @State private var fee = ""
    @State private var notes = ""
    @State private var date = Date()
    @State private var saving = false
    @State private var error: String?

    private var isTrade: Bool { kind == .trade }
    private var isEdit: Bool { existingTrade != nil || existingDividend != nil }
    private var upper: String { ticker.trimmingCharacters(in: .whitespaces).uppercased() }

    /// What the ticker implies, before the user overrides it.
    private var guess: MarketCode? {
        guard !upper.isEmpty else { return nil }
        if let known = store.holdings.first(where: { $0.ticker.uppercased() == upper }) {
            return known.market
        }
        return upper.first?.isNumber == true ? .TW : .US
    }
    private var effectiveMarket: MarketCode { selectedMarket ?? guess ?? market }
    private var currency: String { effectiveMarket.currencyCode }
    private var isTW: Bool { effectiveMarket == .TW }

    private var matchHint: String {
        if let name = store.names[upper], !name.isEmpty, name != upper { return "matched \(name)" }
        guard !upper.isEmpty else { return "auto-detected from the ticker" }
        return guess == .TW ? "auto: numeric code → Taiwan" : "auto: letters → US"
    }

    private var gross: Double? {
        if isTrade {
            guard let s = Double(shares), let p = Double(price), s > 0, p > 0 else { return nil }
            return s * p
        }
        guard let a = Double(price), a > 0 else { return nil }
        return a
    }

    /// TW brokers charge 0.1425% with a NT$20 floor; US brokers here are a flat
    /// dollar. Prefilled, never forced — the field stays editable because real
    /// brokers discount.
    private var autoFee: Double? {
        guard let gross else { return nil }
        return isTW ? max(20, (gross * 0.001425).rounded()) : 1
    }
    private var feeHint: String { autoFee.map { Fmt.number($0, digits: 0) } ?? "—" }

    var body: some View {
        SheetScaffold(title: title, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if isTrade {
                    SegmentedControl(options: [(TradeType.buy, "BUY"), (TradeType.sell, "SELL")],
                                     selection: $type, fill: false)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: Theme.Space.s) {
                        Text("Market").statLabelStyle()
                        Text(matchHint)
                            .font(Theme.Typo.micro)
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                    SegmentedControl(
                        options: [(MarketCode.TW, "Taiwan · TWD"), (MarketCode.US, "US · USD")],
                        selection: Binding(get: { effectiveMarket },
                                           set: { selectedMarket = $0 }))
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.m),
                                    GridItem(.flexible(), spacing: Theme.Space.m)],
                          spacing: Theme.Space.m) {
                    LabeledField(label: "Ticker") {
                        TextField(isTW ? "2330 · 00919" : "NVDA · VOO", text: $ticker)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .focused($focused)
                    }
                    LabeledField(label: isTrade ? "Date" : "Pay date") {
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if isTrade {
                        LabeledField(label: "Shares") {
                            TextField("100", text: $shares)
                                .keyboardType(.decimalPad).focused($focused)
                        }
                    }
                    LabeledField(label: (isTrade ? "Price · " : "Amount · ") + Fmt.symbol(currency)) {
                        TextField(isTrade ? "1050" : "0", text: $price)
                            .keyboardType(.decimalPad).focused($focused)
                    }
                    if isTrade {
                        LabeledField(label: "Fee · auto \(feeHint)") {
                            TextField(feeHint, text: $fee)
                                .keyboardType(.decimalPad).focused($focused)
                        }
                    }
                    LabeledField(label: "Notes") {
                        TextField("optional", text: $notes).focused($focused)
                    }
                }

                HStack {
                    Text(isTW ? "TWSE/TPEx · fees 0.1425% + tax" : "US · flat US$1 commission")
                    Spacer(minLength: Theme.Space.s)
                    Text("\(isTrade ? "Gross" : "Amount") \(gross.map { Fmt.amount($0, currency: currency) } ?? "—")")
                }
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.textSecondary)

                if let error {
                    Text(error)
                        .font(Theme.Typo.detail)
                        .foregroundStyle(Theme.loss)
                        .fixedSize(horizontal: false, vertical: true)
                }

                PrimaryButton(title: isEdit ? "Save changes" : "Save", busy: saving) {
                    Task { await save() }
                }
            }
        }
        .onAppear {
            populate()
            // Revive an idle backend while the user is still typing, so the
            // save doesn't pay the cold start.
            Task { await APIClient.shared.warmUp() }
        }
    }

    private var title: String {
        if isEdit { return isTrade ? "Edit trade" : "Edit dividend" }
        return isTrade ? "Add trade" : "Add dividend"
    }

    // MARK: Populate

    private func populate() {
        if let t = existingTrade {
            type = t.type
            ticker = t.ticker
            shares = trimmed(t.shares)
            price = trimmed(t.price)
            fee = t.fee == 0 ? "" : trimmed(t.fee)
            notes = t.notes ?? ""
            selectedMarket = t.market
            date = Self.parse(t.tradeDate) ?? date
        } else if let d = existingDividend {
            ticker = d.ticker
            price = trimmed(d.amount)
            notes = d.notes ?? ""
            selectedMarket = d.market
            date = Self.parse(d.payDate) ?? date
        } else if let pre = prefillTicker {
            ticker = pre
            selectedMarket = market
        }
    }

    private func trimmed(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    // Parse and format with the same UTC formatter, so a device in a non-UTC
    // zone can't shift a saved date back a day.
    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    private static func parse(_ s: String) -> Date? { iso.date(from: String(s.prefix(10))) }

    // MARK: Validation & save

    /// Rejects a symbol that doesn't belong to the chosen market, and says
    /// which of the two to change. Silently "fixing" it would file the trade
    /// in the wrong currency with the wrong fee.
    private func validate() -> String? {
        guard !upper.isEmpty else { return "Ticker is required." }
        if isTrade, !((Double(shares) ?? 0) > 0 && (Double(price) ?? 0) > 0) {
            return "Shares and price must be positive numbers."
        }
        if !isTrade, !((Double(price) ?? 0) > 0) {
            return "Amount must be a positive number."
        }
        if isTW, upper.range(of: "^[0-9]{4,6}[A-Z]?$", options: .regularExpression) == nil {
            return "“\(upper)” is not a Taiwan stock code (4–6 digits). Switch the market to US, or fix the code."
        }
        if !isTW, upper.range(of: "^[A-Z][A-Z.\\-]{0,5}$", options: .regularExpression) == nil {
            return "“\(upper)” is not a US symbol (letters only). Switch the market to Taiwan, or fix the symbol."
        }
        return nil
    }

    private func save() async {
        if let message = validate() {
            error = message
            return
        }
        saving = true
        error = nil
        let dateString = Self.iso.string(from: date)
        do {
            if isTrade {
                let payload = TradeCreate(
                    type: type, ticker: upper,
                    shares: Double(shares) ?? 0, price: Double(price) ?? 0,
                    tradeDate: dateString,
                    fee: Double(fee) ?? autoFee ?? 0,
                    notes: notes.isEmpty ? nil : notes,
                    market: effectiveMarket)
                if let id = existingTrade?.id {
                    store.upsert(try await APIClient.shared.updateTrade(id, payload))
                } else {
                    store.upsert(try await APIClient.shared.createTrade(payload))
                }
                toasts.show(toastText)
            } else {
                let payload = DividendCreate(
                    ticker: upper, amount: Double(price) ?? 0, payDate: dateString,
                    notes: notes.isEmpty ? nil : notes, market: effectiveMarket)
                if let id = existingDividend?.id {
                    store.upsert(try await APIClient.shared.updateDividend(id, payload))
                } else {
                    store.upsert(try await APIClient.shared.createDividend(payload))
                }
                toasts.show("Dividend \(isEdit ? "updated" : "added") · \(effectiveMarket.displayName)")
            }
            // Dismiss as soon as the write lands; the full refresh (live quotes
            // for holdings/summary) runs behind it.
            dismiss()
            Task { await store.loadAll() }
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            saving = false
        }
    }

    private var toastText: String {
        let where_ = effectiveMarket == .TW ? "Taiwan" : "US"
        if isEdit { return "Trade updated · \(where_)" }
        return type == .buy ? "Buy added · lot open · \(where_)"
                            : "Sell added · FIFO matched · \(where_)"
    }
}
