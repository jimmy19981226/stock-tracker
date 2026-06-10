import SwiftUI

/// Add or edit a dividend payment. Presented as a sheet from the dividend log.
struct DividendFormView: View {
    let market: MarketCode
    let existing: Dividend?

    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    @State private var ticker = ""
    @State private var amount = ""
    @State private var notes = ""
    @State private var date = Date()
    @State private var saving = false
    @State private var error: String?

    private var isEdit: Bool { existing != nil }

    private var isValid: Bool {
        !ticker.trimmingCharacters(in: .whitespaces).isEmpty && (Double(amount) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Dividend") {
                    TextField("Ticker (e.g. \(market == .TW ? "2330" : "AAPL"))", text: $ticker)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Amount", text: $amount)
                        .keyboardType(.decimalPad)
                    DatePicker("Pay date", selection: $date, displayedComponents: .date)
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
            .navigationTitle(isEdit ? "Edit Dividend" : "New Dividend")
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
        guard let d = existing else { return }
        ticker = d.ticker
        amount = d.amount == d.amount.rounded() ? String(Int(d.amount)) : String(d.amount)
        notes = d.notes ?? ""
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        if let dt = f.date(from: String(d.payDate.prefix(10))) { date = dt }
    }

    private func save() async {
        saving = true
        error = nil
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let payload = DividendCreate(
            ticker: ticker.trimmingCharacters(in: .whitespaces).uppercased(),
            amount: Double(amount) ?? 0,
            payDate: f.string(from: date),
            notes: notes.isEmpty ? nil : notes,
            market: market
        )
        do {
            if let existing {
                _ = try await APIClient.shared.updateDividend(existing.id, payload)
            } else {
                _ = try await APIClient.shared.createDividend(payload)
            }
            await store.loadAll()
            dismiss()
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            saving = false
        }
    }
}
