import PDFKit
import SwiftUI
import UIKit

// MARK: - Chat card

/// The report card in the assistant's transcript.
///
/// Three states, because a render is a job and a job can be running, done, or
/// broken — and the one thing it must never do is sit pending forever. The
/// poll gives up after a minute into the failed state, where there is a Retry.
struct ReportCardView: View {
    let job: ReportJob
    let onOpen: (ReportJob) -> Void
    let onRetry: (ReportJob) -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m + 2) {
            ReportThumbnail(image: thumbnail, pulsing: job.status == .pending)

            VStack(alignment: .leading, spacing: 2) {
                Text("PDF report").eyebrowStyle(Theme.accent, size: 11)
                Text(job.title)
                    .font(Theme.Typo.valueSm)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(job.subtitle)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)

                Spacer(minLength: Theme.Space.s)

                switch job.status {
                case .pending:
                    PulsingCaption(text: "Rendering pages from the template…")
                case .ready:
                    HStack(spacing: Theme.Space.s) {
                        Text(job.metaLine)
                            .font(Theme.Typo.captionMed)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Space.xs)
                        Button { onOpen(job) } label: {
                            Text("Open")
                                .font(Theme.Typo.detailMed)
                                .foregroundStyle(.white)
                                .padding(.horizontal, Theme.Space.l)
                                .padding(.vertical, 7)
                                .background(Theme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.segment,
                                                            style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                case .failed:
                    HStack(spacing: Theme.Space.s) {
                        Text("Render job failed")
                            .font(Theme.Typo.captionMed)
                            .foregroundStyle(Theme.loss)
                        Spacer(minLength: Theme.Space.xs)
                        SecondaryButton(title: "Retry") { onRetry(job) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .appCard(padding: Theme.Space.m + 2)
        .task(id: job.status) { await loadThumbnail() }
    }

    /// The page-1 image comes from the PDF the app downloads anyway, rendered
    /// with PDFKit. The handoff suggests Adobe's PDF Services for it; doing it
    /// natively is one fewer service holding credentials, and it works offline.
    private func loadThumbnail() async {
        guard job.status == .ready, thumbnail == nil else { return }
        guard let url = try? await APIClient.shared.downloadReport(job.reportID),
              let document = PDFDocument(url: url), let page = document.page(at: 0)
        else { return }
        thumbnail = page.thumbnail(of: CGSize(width: 174, height: 228), for: .mediaBox)
    }
}

/// The little page standing in for the document: a real page-1 render once
/// there is one, and the navy-headed placeholder until then.
private struct ReportThumbnail: View {
    let image: UIImage?
    let pulsing: Bool
    @State private var dim = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                VStack(spacing: 0) {
                    Rectangle().fill(Theme.heroTop).frame(height: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        bar(0.62, Theme.textTertiary)
                        bar(0.88, Theme.line)
                        Rectangle().fill(Theme.accentSoft).frame(height: 8)
                            .padding(.top, 3)
                        bar(0.92, Theme.line)
                        bar(0.86, Theme.line)
                        bar(0.90, Theme.line)
                        bar(0.74, Theme.line)
                        Spacer(minLength: 0)
                    }
                    .padding(5)
                }
                .background(Color.white)
            }
        }
        .frame(width: 58, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        )
        .opacity(pulsing && dim ? 0.45 : 1)
        .animation(pulsing ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default,
                   value: dim)
        .onAppear { dim = true }
    }

    private func bar(_ fraction: CGFloat, _ colour: Color) -> some View {
        GeometryReader { geo in
            Rectangle().fill(colour).frame(width: geo.size.width * fraction, height: 2)
        }
        .frame(height: 2)
    }
}

// MARK: - Viewer

/// The report, full screen.
///
/// Deliberately on a dark grey ground rather than the app's own: a page is a
/// white sheet, and it reads as a sheet only when the surface behind it is
/// darker than it is.
struct ReportViewerSheet: View {
    let job: ReportJob
    @Environment(\.dismiss) private var dismiss

    @State private var document: PDFDocument?
    @State private var fileURL: URL?
    @State private var page = 0
    @State private var pageCount = 0
    @State private var failure: String?
    @State private var sharing = false

    private static let ground = Color(red: 0.137, green: 0.153, blue: 0.169)  // #23272B

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                if let document {
                    PDFViewer(document: document, page: $page, pageCount: $pageCount)
                } else if let failure {
                    VStack(spacing: Theme.Space.s) {
                        Text("Couldn't open the report")
                            .font(Theme.Typo.row)
                            .foregroundStyle(.white)
                        Text(failure)
                            .font(Theme.Typo.detail)
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                    .padding(Theme.Space.xxl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            bottomBar
        }
        .background(Self.ground.ignoresSafeArea())
        .task { await load() }
        .sheet(isPresented: $sharing) {
            if let fileURL { ShareSheet(items: [fileURL]) }
        }
    }

    private var topBar: some View {
        HStack(spacing: Theme.Space.m) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close report")

            VStack(alignment: .leading, spacing: 1) {
                Text(job.title)
                    .font(Theme.Typo.rowLg)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(job.subtitle)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.s)

            Button { sharing = true } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(fileURL == nil ? .white.opacity(0.3) : .white)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(fileURL == nil)
        }
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.m)
    }

    private var bottomBar: some View {
        HStack(spacing: Theme.Space.xl) {
            step("chevron.left", enabled: page > 0) { page -= 1 }
            Text(pageCount > 0 ? "\(page + 1) / \(pageCount)" : "—")
                .font(Theme.Typo.inlineNum)
                .foregroundStyle(.white)
                .frame(minWidth: 60)
            step("chevron.right", enabled: page + 1 < pageCount) { page += 1 }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.l)
    }

    private func step(_ symbol: String, enabled: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                // Dimmed rather than hidden at the ends: a control that
                // vanishes makes the reader wonder whether they lost it.
                .foregroundStyle(enabled ? Color(white: 0.90) : Color(white: 0.34))
                .frame(width: 44, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(symbol == "chevron.left" ? "Previous report page"
                                                     : "Next report page")
    }

    private func load() async {
        do {
            let url = try await APIClient.shared.downloadReport(job.reportID)
            fileURL = url
            guard let doc = PDFDocument(url: url) else {
                failure = "The file didn't parse as a PDF."
                return
            }
            document = doc
            pageCount = doc.pageCount
        } catch {
            failure = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// `PDFView`, with the page binding kept in step in both directions — tapping
/// the pager scrolls the view, and scrolling the view moves the pager.
private struct PDFViewer: UIViewRepresentable {
    let document: PDFDocument
    @Binding var page: Int
    @Binding var pageCount: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = UIColor(red: 0.137, green: 0.153, blue: 0.169, alpha: 1)
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged, object: view)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        guard let target = document.page(at: min(max(page, 0), document.pageCount - 1)),
              view.currentPage != target else { return }
        view.go(to: target)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: PDFViewer
        weak var view: PDFView?

        init(_ parent: PDFViewer) { self.parent = parent }

        @objc func pageChanged(_ note: Notification) {
            guard let view, let current = view.currentPage,
                  let index = view.document?.index(for: current) else { return }
            if parent.page != index { parent.page = index }
        }
    }
}

/// `UIActivityViewController` over the downloaded file, so the report goes to
/// AirDrop, Files or Mail as a real PDF rather than a link that needs auth.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
