import Foundation

/// A PDF report the backend renders from this account's records.
///
/// The layout lives in a Word template on the server, so the app knows nothing
/// about pages or columns — it asks for a template and a period, polls until
/// the job is done, and shows the file. That is the whole point of the design:
/// a column can move without an App Store release.
struct ReportJob: Codable, Identifiable, Equatable {
    let reportID: String
    var status: Status
    var template: String
    var title: String
    var subtitle: String
    var headline: String
    var rowCount: Int
    var pages: Int
    var bytes: Int
    var renderer: String
    var url: String?
    var error: String?
    var generatedAt: String?
    var cached: Bool?

    var id: String { reportID }

    enum Status: String, Codable {
        case pending, ready, failed
    }

    // Plain camelCase names, no raw values: every model in this app is decoded
    // by APIClient's shared decoder, which converts snake_case for us. Spelling
    // the wire names out here bypassed that conversion — the decoder had
    // already turned `report_id` into `reportId` before these keys were
    // consulted, so every field came back missing and the request threw.
    // Decoded by APIClient's shared decoder, which converts snake_case — so
    // the wire's `report_id` reaches these keys already spelled `reportId`,
    // with a lowercase d. A `reportID` case does not match it, and the whole
    // row silently failed to decode.
    enum CodingKeys: String, CodingKey {
        case reportID = "reportId"
        case status, template, title, subtitle, headline, pages, bytes
        case renderer, url, error, cached
        case rowCount
        case generatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reportID = try c.decode(String.self, forKey: .reportID)
        status = (try? c.decode(Status.self, forKey: .status)) ?? .pending
        template = (try? c.decode(String.self, forKey: .template)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? "Report"
        subtitle = (try? c.decode(String.self, forKey: .subtitle)) ?? ""
        headline = (try? c.decode(String.self, forKey: .headline)) ?? ""
        rowCount = (try? c.decode(Int.self, forKey: .rowCount)) ?? 0
        pages = (try? c.decode(Int.self, forKey: .pages)) ?? 0
        bytes = (try? c.decode(Int.self, forKey: .bytes)) ?? 0
        renderer = (try? c.decode(String.self, forKey: .renderer)) ?? ""
        url = try? c.decode(String.self, forKey: .url)
        error = try? c.decode(String.self, forKey: .error)
        generatedAt = try? c.decode(String.self, forKey: .generatedAt)
        cached = try? c.decode(Bool.self, forKey: .cached)
    }

    /// "PDF · 5 pages · 410 KB" — what the card's meta line reads.
    var metaLine: String {
        var parts = ["PDF"]
        if pages > 0 { parts.append("\(pages) page\(pages == 1 ? "" : "s")") }
        if bytes > 0 {
            let kb = Double(bytes) / 1024
            parts.append(kb >= 1024 ? String(format: "%.1f MB", kb / 1024)
                                    : String(format: "%.0f KB", kb))
        }
        return parts.joined(separator: " · ")
    }
}

/// One template the backend offers, with what it is and how long it runs.
struct ReportTemplate: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let pages: Int
}

struct ReportCatalog: Codable {
    var reports: [ReportJob] = []
    var templates: [ReportTemplate] = []
    /// "adobe" or "local" — which renderer the server is actually using.
    var renderer: String = ""
}

/// The period a report covers. Matches the backend's own vocabulary.
enum ReportPeriod: String, CaseIterable, Identifiable {
    case ytd, lastYear, last12m, all

    var id: String { rawValue }

    /// What goes on the wire. Last year is a calendar year, resolved now so a
    /// report generated in January still means the year the user tapped.
    var wireValue: String {
        switch self {
        case .ytd: return "ytd"
        case .lastYear: return "year:\(Calendar.current.component(.year, from: Date()) - 1)"
        case .last12m: return "last_12m"
        case .all: return "all"
        }
    }

    var label: String {
        switch self {
        case .ytd: return "YTD"
        case .lastYear: return String(Calendar.current.component(.year, from: Date()) - 1)
        case .last12m: return "Last 12M"
        case .all: return "All"
        }
    }
}
