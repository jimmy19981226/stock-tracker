import PhotosUI
import SwiftUI
import UIKit

/// AI import: a photo of a brokerage statement becomes a reviewed list of
/// trades and dividends.
///
/// Four steps, and the third is the point of the whole screen — **nothing is
/// written until the review is confirmed.** A vision model misreading a decimal
/// is not a hypothetical, so every row is shown with what it parsed to, rows
/// that duplicate an existing record are flagged, and any row can be dropped.
struct ImportRecordsView: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.dismiss) private var dismiss

    private enum Step { case pick, parsing, review, done }

    @State private var step: Step = .pick
    @State private var photoItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var preview: UIImage?
    @State private var note = ""
    @State private var parsed: ParsedRecords?
    @State private var include: [String: Bool] = [:]
    @State private var error: String?
    @State private var submitting = false

    var body: some View {
        ModalScaffold(title: "AI import", onClose: { dismiss() }) {
            switch step {
            case .pick: pickStep
            case .parsing: parsingStep
            case .review: reviewStep
            case .done: doneStep
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
    }

    // MARK: Step 0 — pick

    private var pickStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(spacing: Theme.Space.xs) {
                if let preview {
                    Image(uiImage: preview)
                        .resizable().scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
                        .padding(.bottom, Theme.Space.xs)
                }
                Text("Snap a brokerage statement")
                    .font(Theme.Typo.headingXs)
                    .foregroundStyle(Theme.text)
                Text("A vision model extracts trades and dividends for review — nothing is written until you confirm. Taiwan company names resolve to stock codes.")
                    .font(Theme.Typo.detail)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 270)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Theme.Space.l)

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Text(imageData == nil ? "Choose an image" : "Choose a different image")
                        .font(Theme.Typo.buttonSm)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Space.xl)
                        .padding(.vertical, 11)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.vertical, 26)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.accentSoft, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            )

            LabeledField(label: "Note for the model (optional)") {
                TextField("US trades are in USD · the 優群 row is 3217", text: $note, axis: .vertical)
                    .lineLimit(1...3)
            }

            if let error {
                Text(error)
                    .font(Theme.Typo.detail)
                    .foregroundStyle(Theme.loss)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PrimaryButton(title: "Read with AI", disabled: imageData == nil) {
                Task { await parse() }
            }
        }
    }

    // MARK: Step 1 — parsing

    private var parsingStep: some View {
        VStack(spacing: Theme.Space.l) {
            PulsingLabel(text: "✦ Parsing with vision model…")
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("✓ Reading document")
                Text("✓ Resolving company names to codes")
                Text("Matching columns…")
            }
            .font(Theme.Typo.detail)
            .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: Step 2 — review

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(summaryLine)
                .font(Theme.Typo.detail)
                .foregroundStyle(Theme.textSecondary)

            if let notes = parsed?.notes, !notes.isEmpty {
                Text(notes)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(rows, id: \.key) { row in
                ParsedRow(row: row, isOn: binding(row.key))
            }

            if rows.isEmpty {
                EmptyState(icon: "doc.text.magnifyingglass", title: "Nothing found",
                           message: "The model couldn't find trades or dividends in that image. Try a clearer photo.")
            }

            if let error {
                Text(error)
                    .font(Theme.Typo.detail)
                    .foregroundStyle(Theme.loss)
            }

            PrimaryButton(title: submitTitle,
                          disabled: selectedCount == 0, busy: submitting) {
                Task { await submit() }
            }
        }
    }

    // MARK: Step 3 — done

    private var doneStep: some View {
        VStack(spacing: Theme.Space.xs) {
            Text("✓ \(selectedCount) records added")
                .font(Theme.Typo.headingSm)
                .foregroundStyle(Theme.gain)
            Text("Find them under Trades and Dividends.")
                .font(Theme.Typo.detail)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: Rows

    /// One parsed record, flattened so trades and dividends share a list.
    struct Row {
        let key: String
        let tag: String
        let style: TagChip.Style
        let ticker: String
        let name: String
        let detail: String
        let duplicate: Bool
    }

    private var rows: [Row] {
        guard let parsed else { return [] }
        var out: [Row] = []
        for (i, t) in parsed.trades.enumerated() {
            let dupe = store.trades.contains {
                $0.ticker.uppercased() == t.ticker.uppercased()
                    && $0.tradeDate.hasPrefix(t.date.prefix(10))
                    && abs($0.shares - t.shares) < 1e-6
                    && abs($0.price - t.price) < 1e-6
            }
            out.append(Row(key: "t\(i)",
                           tag: t.type == .buy ? "BUY" : "SELL",
                           style: t.type == .buy ? .accent : .outline,
                           ticker: t.ticker,
                           name: store.name(for: t.ticker),
                           detail: "\(Fmt.shares(t.shares)) × \(Fmt.number(t.price, digits: 2)) · \(t.date.prefix(10))"
                               + (t.fee.map { " · fee \(Fmt.number($0, digits: 0))" } ?? ""),
                           duplicate: dupe))
        }
        for (i, d) in parsed.dividends.enumerated() {
            let dupe = store.dividends.contains {
                $0.ticker.uppercased() == d.ticker.uppercased()
                    && $0.payDate.hasPrefix(d.date.prefix(10))
                    && abs($0.amount - d.amount) < 1e-6
            }
            out.append(Row(key: "d\(i)", tag: "DIV", style: .neutral,
                           ticker: d.ticker, name: store.name(for: d.ticker),
                           detail: "\(Fmt.number(d.amount, digits: 2)) · \(d.date.prefix(10))"
                               + (d.notes.map { " · \($0)" } ?? ""),
                           duplicate: dupe))
        }
        return out
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { include[key] ?? true }, set: { include[key] = $0 })
    }

    private var selectedCount: Int { rows.filter { include[$0.key] ?? true }.count }

    private var summaryLine: String {
        let trades = parsed?.trades.count ?? 0
        let divs = parsed?.dividends.count ?? 0
        let dupes = rows.filter(\.duplicate).count
        var line = "Found \(trades) trade\(trades == 1 ? "" : "s") and \(divs) dividend\(divs == 1 ? "" : "s") — review before saving."
        if dupes > 0 { line += " \(dupes) look like duplicates and are unticked." }
        return line
    }

    private var submitTitle: String {
        selectedCount == 0 ? "Nothing selected" : "Add \(selectedCount) record\(selectedCount == 1 ? "" : "s")"
    }

    // MARK: Actions

    private func load(_ item: PhotosPickerItem) async {
        error = nil
        do {
            guard var data = try await item.loadTransferable(type: Data.self) else {
                throw APIError.transport("Couldn't read that image")
            }
            // Re-encode (and downscale very large photos) to keep the upload
            // small — a 12 MP original adds seconds for no extra accuracy.
            if let img = UIImage(data: data) {
                let maxDim: CGFloat = 2200
                let scale = min(1, maxDim / max(img.size.width, img.size.height))
                let target = CGSize(width: img.size.width * scale, height: img.size.height * scale)
                let renderer = UIGraphicsImageRenderer(size: target)
                let resized = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: target)) }
                data = resized.jpegData(compressionQuality: 0.8) ?? data
                preview = UIImage(data: data)
            }
            imageData = data
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            photoItem = nil
        }
    }

    private func parse() async {
        guard let data = imageData else { return }
        error = nil
        step = .parsing
        do {
            let result = try await APIClient.shared.parseRecords(imageData: data, instructions: note)
            parsed = result
            include = [:]
            for row in rows where row.duplicate { include[row.key] = false }
            step = .review
        } catch {
            // Keep the image and the note so the note can be tweaked and retried.
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            step = .pick
        }
    }

    private func submit() async {
        guard let parsed else { return }
        submitting = true
        error = nil
        var failures = 0
        for (i, row) in parsed.trades.enumerated() where include["t\(i)"] ?? true {
            let payload = TradeCreate(type: row.type, ticker: row.ticker, shares: row.shares,
                                      price: row.price, tradeDate: row.date, fee: row.fee ?? 0,
                                      notes: row.notes, market: nil)  // backend infers TW/US
            do { _ = try await APIClient.shared.createTrade(payload) } catch { failures += 1 }
        }
        for (i, row) in parsed.dividends.enumerated() where include["d\(i)"] ?? true {
            let payload = DividendCreate(ticker: row.ticker, amount: row.amount,
                                         payDate: row.date, notes: row.notes, market: nil)
            do { _ = try await APIClient.shared.createDividend(payload) } catch { failures += 1 }
        }
        await store.loadAll()
        submitting = false
        if failures > 0 {
            error = "\(failures) record\(failures == 1 ? "" : "s") failed to add — the rest were saved."
            return
        }
        step = .done
        toasts.show("\(selectedCount) records imported")
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        dismiss()
    }
}

/// One reviewed row, with its own include switch. Duplicates arrive unticked
/// and say so — a silent skip would hide a real second purchase on the same day.
private struct ParsedRow: View {
    let row: ImportRecordsView.Row
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            TagChip(text: row.tag, style: row.style, width: 56)
            VStack(alignment: .leading, spacing: 1) {
                TickerLine(ticker: row.ticker, name: row.name)
                Text(row.detail + (row.duplicate ? " · duplicate of an existing record" : ""))
                    .font(Theme.Typo.micro)
                    .foregroundStyle(row.duplicate ? Theme.loss : Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.Space.s)
            Toggle("", isOn: $isOn).labelsHidden().tint(Theme.accent)
        }
        .padding(Theme.Space.m + 2)
        .appCard(padding: 0, radius: Theme.Radius.inset)
    }
}

/// The parsing headline, breathing. Motion here is state, not decoration — it
/// is the only signal that a request taking up to a minute is still alive.
struct PulsingLabel: View {
    let text: String
    @State private var dim = false

    var body: some View {
        Text(text)
            .font(Theme.Typo.headingXs)
            .foregroundStyle(Theme.text)
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}
