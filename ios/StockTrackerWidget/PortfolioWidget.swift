import SwiftUI
import WidgetKit

// MARK: - Timeline

struct PortfolioEntry: TimelineEntry {
    let date: Date
    let data: PortfolioWidgetData?
}

struct PortfolioProvider: TimelineProvider {
    func placeholder(in context: Context) -> PortfolioEntry {
        PortfolioEntry(date: Date(), data: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (PortfolioEntry) -> Void) {
        let data = WidgetSharedStore.read() ?? (context.isPreview ? .sample : nil)
        completion(PortfolioEntry(date: Date(), data: data))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PortfolioEntry>) -> Void) {
        let entry = PortfolioEntry(date: Date(), data: WidgetSharedStore.read())
        // The app reloads timelines on every refresh; this just bounds staleness
        // if the app isn't opened for a while.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Colors / formatting

private enum WTheme {
    static let bg = Color(red: 0.02, green: 0.027, blue: 0.047)
    static let text = Color(red: 0.91, green: 0.925, blue: 0.95)
    static let muted = Color(red: 0.54, green: 0.58, blue: 0.65)
    static let up = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let down = Color(red: 0.97, green: 0.44, blue: 0.44)
}

private func money(_ v: Double?, _ currency: String, digits: Int = 0) -> String {
    guard let v else { return "—" }
    let sym = currency == "TWD" ? "NT$" : (currency == "USD" ? "US$" : "")
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = digits
    f.minimumFractionDigits = digits
    return sym + (f.string(from: NSNumber(value: v)) ?? "\(v)")
}

private func signed(_ v: Double?, _ currency: String) -> String {
    guard let v else { return "—" }
    let sign = v > 0 ? "+" : (v < 0 ? "−" : "")
    return sign + money(abs(v), currency)
}

private func plColor(_ v: Double?) -> Color {
    guard let v, v != 0 else { return WTheme.muted }
    return v > 0 ? WTheme.up : WTheme.down
}

// MARK: - Views

struct PortfolioWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PortfolioEntry

    var body: some View {
        Group {
            if let d = entry.data {
                switch family {
                case .systemMedium: medium(d)
                default: small(d)
                }
            } else {
                empty
            }
        }
        .containerBackground(WTheme.bg, for: .widget)
    }

    private func small(_ d: PortfolioWidgetData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Net worth")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WTheme.muted)
            Text(money(d.netWorthTWD, "TWD"))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(WTheme.text)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(signed(d.todayPLTWD, "TWD") + todayPctSuffix(d))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(plColor(d.todayPLTWD))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Spacer(minLength: 0)
            updated(d)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func medium(_ d: PortfolioWidgetData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Net worth")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(WTheme.muted)
                    Text(money(d.netWorthTWD, "TWD"))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(WTheme.text)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Today")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WTheme.muted)
                    Text(signed(d.todayPLTWD, "TWD"))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(plColor(d.todayPLTWD))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(todayPctText(d))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(plColor(d.todayPLTWD))
                }
            }
            Divider().overlay(WTheme.muted.opacity(0.3))
            HStack(spacing: 12) {
                marketCol("🇹🇼 Taiwan", value: money(d.twValue, "TWD"), today: signed(d.twTodayPL, "TWD"), pl: d.twTodayPL)
                marketCol("🇺🇸 US", value: money(d.usValue, "USD"), today: signed(d.usTodayPL, "USD"), pl: d.usTodayPL)
            }
            Spacer(minLength: 0)
            updated(d)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func marketCol(_ title: String, value: String, today: String, pl: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(WTheme.muted)
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(WTheme.text).minimumScaleFactor(0.6).lineLimit(1)
            Text(today).font(.system(size: 11, weight: .medium)).foregroundStyle(plColor(pl)).minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("✦ Stock Studio").font(.system(size: 13, weight: .bold)).foregroundStyle(WTheme.text)
            Text("Open the app once to\nload your portfolio")
                .font(.system(size: 11)).foregroundStyle(WTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func updated(_ d: PortfolioWidgetData) -> some View {
        Text("Updated \(d.updatedAt.formatted(date: .omitted, time: .shortened))")
            .font(.system(size: 10))
            .foregroundStyle(WTheme.muted)
    }

    private func todayPctText(_ d: PortfolioWidgetData) -> String {
        guard let p = d.todayPLPct else { return "" }
        let sign = p > 0 ? "+" : (p < 0 ? "−" : "")
        return "\(sign)\(String(format: "%.2f", abs(p)))%"
    }

    private func todayPctSuffix(_ d: PortfolioWidgetData) -> String {
        let t = todayPctText(d)
        return t.isEmpty ? "" : "  \(t)"
    }
}

// MARK: - Widget

struct PortfolioWidget: Widget {
    let kind = "PortfolioWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PortfolioProvider()) { entry in
            PortfolioWidgetView(entry: entry)
        }
        .configurationDisplayName("Portfolio")
        .description("Your net worth and today’s gain/loss at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

extension PortfolioWidgetData {
    static let sample = PortfolioWidgetData(
        netWorthTWD: 2881899, netWorthUSD: 90998, todayPLTWD: 28640, todayPLPct: 1.01,
        twValue: 1597048, twTodayPL: 18420, usValue: 40500, usTodayPL: 322,
        updatedAt: Date()
    )
}
