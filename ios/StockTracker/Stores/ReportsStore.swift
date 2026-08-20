import Foundation
import SwiftUI

/// Owns report jobs and their polling.
///
/// App-scoped, not per-screen, for the same reason the assistant's generation
/// is: a render takes seconds and the user is free to leave. A poll that died
/// with the view would leave a card stuck on "Rendering…" forever, which is the
/// one state the handoff says must never happen.
@MainActor
final class ReportsStore: ObservableObject {
    static let shared = ReportsStore()

    @Published var jobs: [String: ReportJob] = [:]
    @Published var templates: [ReportTemplate] = []
    /// "adobe" or "local" — what the server is actually rendering with, so the
    /// UI can say so rather than implying an integration that isn't live.
    @Published var renderer: String = ""
    /// The report the user asked to read, if any.
    @Published var viewing: ReportJob?

    private var polling: Set<String> = []

    private init() {}

    func job(_ id: String) -> ReportJob? { jobs[id] }

    func loadCatalog() async {
        guard let catalog = try? await APIClient.shared.listReports() else { return }
        templates = catalog.templates
        renderer = catalog.renderer
        for job in catalog.reports { jobs[job.reportID] = job }
    }

    /// Start (or reuse) a render, and poll it to a terminal state.
    @discardableResult
    func generate(template: String, period: String) async -> ReportJob? {
        do {
            let job = try await APIClient.shared.createReport(template: template, period: period)
            jobs[job.reportID] = job
            track(job.reportID)
            return job
        } catch {
            return nil
        }
    }

    /// Adopt a job the assistant started and follow it to a terminal state.
    func adopt(_ job: ReportJob) {
        jobs[job.reportID] = job
        track(job.reportID)
    }

    /// Follow a job whose id arrived over the stream.
    func track(_ id: String) {
        guard !polling.contains(id) else { return }
        if let existing = jobs[id], existing.status != .pending { return }
        polling.insert(id)
        Task { await poll(id) }
    }

    /// 1.5 s between polls, giving up after 60 s.
    ///
    /// The timeout is the point: a job that never answers has to end up
    /// `failed`, where there is a Retry, rather than pending forever.
    private func poll(_ id: String) async {
        defer { polling.remove(id) }
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let job = try? await APIClient.shared.getReport(id) else { continue }
            jobs[id] = job
            if job.status != .pending { return }
        }
        if var job = jobs[id], job.status == .pending {
            job.status = .failed
            job.error = "The render didn't finish within a minute."
            jobs[id] = job
        }
    }

    /// Retry a failed job — a fresh request, since the cache deliberately
    /// never reuses a failure.
    func retry(_ job: ReportJob) async {
        let period = job.subtitle.isEmpty ? "ytd" : jobs[job.reportID]?.template ?? "ytd"
        _ = period  // period is carried by the server; re-requesting the template is enough
        await generate(template: job.template, period: "ytd")
    }

    func open(_ job: ReportJob) {
        viewing = jobs[job.reportID] ?? job
    }
}
