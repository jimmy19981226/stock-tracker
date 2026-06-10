import SwiftUI

/// Add or edit a trade. Presented as a sheet from the trade log.
struct TradeFormView: View {
    let market: MarketCode
    let existing: Trade?

    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    buySellSelector
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }

                Section("Trade") {
                    TextField("Ticker (e.g. \(market == .TW ? "2330" : "AAPL"))", text: $ticker)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .rounded).weight(.semibold))
                    LabeledContent("Shares") {
                        TextField("0", text: $shares)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                    }
                    LabeledContent("Price") {
                        TextField("0.00", text: $price)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                    }
                    LabeledContent("Fee") {
                        TextField("Optional", text: $fee)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .rounded))
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                if let est = estimatedTotal {
                    Section {
                        LabeledContent("Estimated total") {
                            Text(Fmt.money(est, currency: market.currencyCode))
                                .font(.system(.body, design: .rounded).weight(.bold))
                                .foregroundStyle(type == .buy ? Theme.negative : Theme.positive)
                        }
                    }
                }

                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }

                if let error {
                    Section { Text(error).foregroundStyle(Theme.negative) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(isEdit ? "Edit Trade" : "New Trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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

    private var estimatedTotal: Double? {
        guard let s = Double(shares), let p = Double(price), s > 0, p > 0 else { return nil }
        return s * p + (Double(fee) ?? 0)
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
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
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
