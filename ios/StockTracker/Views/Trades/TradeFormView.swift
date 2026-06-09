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
                    Picker("Type", selection: $type) {
                        Text("Buy").tag(TradeType.buy)
                        Text("Sell").tag(TradeType.sell)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Trade") {
                    TextField("Ticker (e.g. \(market == .TW ? "2330" : "AAPL"))", text: $ticker)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Shares", text: $shares)
                        .keyboardType(.decimalPad)
                    TextField("Price", text: $price)
                        .keyboardType(.decimalPad)
                    TextField("Fee (optional)", text: $fee)
                        .keyboardType(.decimalPad)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }

                if let error {
                    Section { Text(error).foregroundStyle(Theme.negative) }
                }
            }
            .navigationTitle(isEdit ? "Edit Trade" : "New Trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() }
                    else { Button("Save") { Task { await save() } }.disabled(!isValid) }
                }
            }
            .onAppear(perform: populate)
        }
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
