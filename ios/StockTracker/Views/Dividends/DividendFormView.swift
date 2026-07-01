import SwiftUI

/// Add or edit a dividend — a custom flat sheet matching the trade form: big
/// ticker entry, hairline-separated rows, and a full-width green CTA.
struct DividendFormView: View {
    let market: MarketCode
    let existing: Dividend?
    /// Pre-fills the ticker when adding from a stock's detail page.
    var prefillTicker: String? = nil

    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

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
            ScrollView {
                VStack(spacing: 0) {
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

                    // Amount
                    HStack {
                        Text("Amount")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                        Spacer()
                        TextField("0.00", text: $amount)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.positive)
                            .frame(maxWidth: 170)
                            .focused($focused)
                    }
                    .padding(.vertical, 14)
                    separator

                    // Pay date
                    HStack {
                        Text("Pay date")
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
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isEdit ? "Edit Dividend" : "New Dividend")
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
                    title: isEdit ? "Save Changes" : "Add Dividend",
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

    private func populate() {
        guard let d = existing else {
            if let pre = prefillTicker { ticker = pre }
            return
        }
        ticker = d.ticker
        amount = d.amount == d.amount.rounded() ? String(Int(d.amount)) : String(d.amount)
        notes = d.notes ?? ""
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        if let dt = f.date(from: String(d.payDate.prefix(10))) { date = dt }
    }

    private func save() async {
        saving = true
        error = nil
        // UTC to match the populate formatter — avoids shifting the saved date
        // back a day on devices west of UTC.
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
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
