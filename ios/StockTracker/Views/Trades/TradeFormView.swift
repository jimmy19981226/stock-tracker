import SwiftUI

/// Add or edit a trade — a custom flat sheet (not a stock Form): Buy/Sell pills,
/// a big ticker entry, hairline-separated input rows, a live estimated total,
/// and a full-width green CTA.
struct TradeFormView: View {
    let market: MarketCode
    let existing: Trade?

    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    @State private var type: TradeType = .buy
    @State private var ticker = ""
    @State private var shares = ""
    @State private var price = ""
    @State private var fee = ""
    @State private var notes = ""
    @State private var date = Date()
    @State private var saving = false
    @State private var error: String?

    private var isEdit: Bool { existing != nil }

    private var isValid: Bool {
        !ticker.trimmingCharacters(in: .whitespaces).isEmpty
            && (Double(shares) ?? 0) > 0
            && (Double(price) ?? 0) > 0
    }

    private var estimatedTotal: Double? {
        guard let s = Double(shares), let p = Double(price), s > 0, p > 0 else { return nil }
        return s * p + (Double(fee) ?? 0)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    buySellSelector
                        .padding(.bottom, 22)

                    // Ticker — the hero input.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TICKER")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.mutedText)
                            .tracking(0.6)
                        TextField(market == .TW ? "2330" : "AAPL", text: $ticker)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.primaryText)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .focused($focused)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 10)
                    separator

                    inputRow("Shares", text: $shares, placeholder: "0", bold: true)
                    inputRow("Price", text: $price, placeholder: "0.00", bold: true)
                    inputRow("Fee", text: $fee, placeholder: "Optional")

                    // Date
                    HStack {
                        Text("Date")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                        Spacer()
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .labelsHidden()
                    }
                    .padding(.vertical, 9)
                    separator

                    // Notes
                    HStack(alignment: .firstTextBaseline) {
                        Text("Notes")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                        Spacer()
                        TextField("Optional", text: $notes, axis: .vertical)
                            .lineLimit(1...3)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .rounded))
                            .focused($focused)
                    }
                    .padding(.vertical, 14)
                    separator

                    if let est = estimatedTotal {
                        HStack {
                            Text("Estimated total")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.primaryText)
                            Spacer()
                            Text(Fmt.money(est, currency: market.currencyCode))
                                .font(.system(.title3, design: .rounded).weight(.bold))
                                .foregroundStyle(type == .buy ? Theme.negative : Theme.positive)
                        }
                        .padding(.vertical, 16)
                    }

                    if let error {
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(Theme.negative)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 10)
                    }
                }
                .padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isEdit ? "Edit Trade" : "New Trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false }
                }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(
                    title: isEdit ? "Save Changes" : (type == .buy ? "Buy" : "Sell"),
                    disabled: !isValid,
                    busy: saving
                ) {
                    Task { await save() }
                }
            }
            .onAppear(perform: populate)
        }
        .presentationBackground(Theme.bg)
        .presentationDragIndicator(.visible)
    }

    private var separator: some View {
        Rectangle().fill(Theme.stroke).frame(height: 1)
    }

    private func inputRow(_ label: String, text: Binding<String>,
                          placeholder: String, bold: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                TextField(placeholder, text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(bold
                          ? .system(.title3, design: .rounded).weight(.semibold)
                          : .system(.body, design: .rounded))
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: 170)
                    .focused($focused)
            }
            .padding(.vertical, 14)
            separator
        }
    }

    /// Two-pill Buy / Sell selector — green for buy, red for sell.
    private var buySellSelector: some View {
        HStack(spacing: 10) {
            selectorPill("Buy", .buy, Theme.positive)
            selectorPill("Sell", .sell, Theme.negative)
        }
    }

    private func selectorPill(_ label: String, _ value: TradeType, _ color: Color) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { type = value }
        } label: {
            Text(label)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(type == value ? .black : Theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(type == value ? color : Theme.cardElevated)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func populate() {
        guard let t = existing else { return }
        type = t.type
        ticker = t.ticker
        shares = trimmed(t.shares)
        price = trimmed(t.price)
        fee = t.fee == 0 ? "" : trimmed(t.fee)
        notes = t.notes ?? ""
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        if let d = f.date(from: String(t.tradeDate.prefix(10))) { date = d }
    }

    private func trimmed(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    private func save() async {
        saving = true
        error = nil
        // Match the UTC formatter used to PARSE the date when populating, so a
        // device in a non-UTC zone doesn't shift the saved date back a day.
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        let payload = TradeCreate(
            type: type,
            ticker: ticker.trimmingCharacters(in: .whitespaces).uppercased(),
            shares: Double(shares) ?? 0,
            price: Double(price) ?? 0,
            tradeDate: f.string(from: date),
            fee: Double(fee) ?? 0,
            notes: notes.isEmpty ? nil : notes,
            market: market
        )
        do {
            if let existing {
                _ = try await APIClient.shared.updateTrade(existing.id, payload)
            } else {
                _ = try await APIClient.shared.createTrade(payload)
            }
            await store.loadAll()
            dismiss()
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            saving = false
        }
    }
}
