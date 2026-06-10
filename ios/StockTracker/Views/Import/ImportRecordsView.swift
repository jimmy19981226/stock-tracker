import PhotosUI
import SwiftUI
import UIKit

/// AI image import: pick a brokerage screenshot → the backend's vision model
/// extracts trades + dividends → review each row with a toggle → confirm to add.
/// Nothing is written until the user confirms; each confirmed row goes through
/// the normal create endpoints (the backend infers TW/US from the ticker).
struct ImportRecordsView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case pick
        case parsing
        case review
        case submitting
    }

    @State private var phase: Phase = .pick
    @State private var photoItem: PhotosPickerItem?
    @State private var parsed: ParsedRecords?
    @State private var tradeOn: [Bool] = []
    @State private var dividendOn: [Bool] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                switch phase {
                case .pick: pickView
                case .parsing: parsingView
                case .review, .submitting: reviewView
                }
            }
            .navigationTitle("Import from Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationBackground(Theme.bg)
        .presentationDragIndicator(.visible)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
    }

    // MARK: - Pick

    private var pickView: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accent)
            }
            VStack(spacing: 6) {
                Text("Import trades from a screenshot")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(Theme.primaryText)
                Text("Pick a brokerage screenshot or statement photo.\nAI reads it and extracts every trade and dividend\nfor you to review — nothing is added until you confirm.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            PhotosPicker(selection: $photoItem, matching: .images) {
                Text("Choose Image")
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 13)
                    .background(Theme.accent)
                    .clipShape(Capsule())
            }
            if let error {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(Theme.negative)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding(24)
    }

    // MARK: - Parsing

    private var parsingView: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.4)
            Text("AI is reading your statement…")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(Theme.primaryText)
            Text("This can take up to a minute.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: - Review

    private var reviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let notes = parsed?.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }

                if let trades = parsed?.trades, !trades.isEmpty {
                    SectionHeader("Trades") {
                        Text("\(selectedTradeCount)/\(trades.count)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(trades.enumerated()), id: \.offset) { i, row in
                            tradeRow(row, isOn: bindingForTrade(i))
                        }
                    }
                }

                if let divs = parsed?.dividends, !divs.isEmpty {
                    SectionHeader("Dividends") {
                        Text("\(selectedDividendCount)/\(divs.count)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(divs.enumerated()), id: \.offset) { i, row in
                            dividendRow(row, isOn: bindingForDividend(i))
                        }
                    }
                }

                if (parsed?.trades.isEmpty ?? true) && (parsed?.dividends.isEmpty ?? true) {
                    EmptyState(icon: "doc.text.magnifyingglass",
                               title: "Nothing found",
                               message: "The AI couldn't find trades or dividends in that image. Try a clearer screenshot.")
                }

                if let error {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(Theme.negative)
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(
                title: submitTitle,
                disabled: selectedTradeCount + selectedDividendCount == 0,
                busy: phase == .submitting
            ) {
                Task { await submit() }
            }
        }
    }

    private func tradeRow(_ row: ParsedTradeRow, isOn: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("", isOn: isOn).labelsHidden()
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.ticker)
                            .font(.system(.body, design: .rounded).weight(.bold))
                            .foregroundStyle(Theme.primaryText)
                        Text(row.type == .buy ? "Buy" : "Sell")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(row.type == .buy ? Theme.positive : Theme.negative)
                    }
                    Text(row.date)
                        .font(.caption)
                        .foregroundStyle(Theme.mutedText)
                }
                Spacer()
                Text("\(Fmt.shares(row.shares)) @ \(Fmt.number(row.price))")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
            }
            .padding(.vertical, 10)
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }

    private func dividendRow(_ row: ParsedDividendRow, isOn: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("", isOn: isOn).labelsHidden()
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.ticker)
                        .font(.system(.body, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                    Text(row.date)
                        .font(.caption)
                        .foregroundStyle(Theme.mutedText)
                }
                Spacer()
                Text("+\(Fmt.number(row.amount))")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(Theme.positive)
            }
            .padding(.vertical, 10)
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }

    // MARK: - Selection helpers

    private var selectedTradeCount: Int { tradeOn.filter { $0 }.count }
    private var selectedDividendCount: Int { dividendOn.filter { $0 }.count }

    private var submitTitle: String {
        var parts: [String] = []
        if selectedTradeCount > 0 { parts.append("\(selectedTradeCount) trade\(selectedTradeCount == 1 ? "" : "s")") }
        if selectedDividendCount > 0 { parts.append("\(selectedDividendCount) dividend\(selectedDividendCount == 1 ? "" : "s")") }
        return parts.isEmpty ? "Add Records" : "Add \(parts.joined(separator: " · "))"
    }

    private func bindingForTrade(_ i: Int) -> Binding<Bool> {
        Binding(get: { tradeOn.indices.contains(i) ? tradeOn[i] : false },
                set: { if tradeOn.indices.contains(i) { tradeOn[i] = $0 } })
    }

    private func bindingForDividend(_ i: Int) -> Binding<Bool> {
        Binding(get: { dividendOn.indices.contains(i) ? dividendOn[i] : false },
                set: { if dividendOn.indices.contains(i) { dividendOn[i] = $0 } })
    }

    // MARK: - Actions

    private func load(_ item: PhotosPickerItem) async {
        error = nil
        phase = .parsing
        do {
            guard var data = try await item.loadTransferable(type: Data.self) else {
                throw APIError.transport("Couldn't read that image")
            }
            // Re-encode (and downscale very large photos) to keep the upload small.
            if let img = UIImage(data: data) {
                let maxDim: CGFloat = 2200
                let scale = min(1, maxDim / max(img.size.width, img.size.height))
                let target = CGSize(width: img.size.width * scale, height: img.size.height * scale)
                let renderer = UIGraphicsImageRenderer(size: target)
                let resized = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: target)) }
                data = resized.jpegData(compressionQuality: 0.8) ?? data
            }
            let result = try await APIClient.shared.parseRecords(imageData: data)
            parsed = result
            tradeOn = Array(repeating: true, count: result.trades.count)
            dividendOn = Array(repeating: true, count: result.dividends.count)
            phase = .review
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            phase = .pick
            photoItem = nil
        }
    }

    private func submit() async {
        guard let parsed else { return }
        phase = .submitting
        error = nil
        var failures = 0
        for (i, row) in parsed.trades.enumerated() where tradeOn.indices.contains(i) && tradeOn[i] {
            let payload = TradeCreate(
                type: row.type, ticker: row.ticker, shares: row.shares,
                price: row.price, tradeDate: row.date, fee: row.fee ?? 0,
                notes: row.notes, market: nil  // backend infers TW/US per ticker
            )
            do { _ = try await APIClient.shared.createTrade(payload) }
            catch { failures += 1 }
        }
        for (i, row) in parsed.dividends.enumerated() where dividendOn.indices.contains(i) && dividendOn[i] {
            let payload = DividendCreate(
                ticker: row.ticker, amount: row.amount,
                payDate: row.date, notes: row.notes, market: nil
            )
            do { _ = try await APIClient.shared.createDividend(payload) }
            catch { failures += 1 }
        }
        await store.loadAll()
        if failures > 0 {
            error = "\(failures) record\(failures == 1 ? "" : "s") failed to add — the rest were saved."
            phase = .review
        } else {
            dismiss()
        }
    }
}
