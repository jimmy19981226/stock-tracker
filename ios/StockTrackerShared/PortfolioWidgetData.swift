import Foundation
import WidgetKit

/// Snapshot of the portfolio the Home Screen widget renders. The main app
/// writes this to a shared App Group container whenever it refreshes the
/// overview; the widget extension reads it. Keeping the widget snapshot-based
/// (rather than having the extension hit the network + handle Google auth)
/// makes it reliable and battery-cheap — it shows the app's last-known numbers
/// with an "updated" timestamp.
public struct PortfolioWidgetData: Codable {
    public var netWorthTWD: Double?
    public var netWorthUSD: Double?
    /// Combined today's P&L, expressed in TWD.
    public var todayPLTWD: Double?
    public var todayPLPct: Double?
    public var twValue: Double?
    public var twTodayPL: Double?
    public var usValue: Double?
    public var usTodayPL: Double?
    public var updatedAt: Date

    public init(
        netWorthTWD: Double? = nil,
        netWorthUSD: Double? = nil,
        todayPLTWD: Double? = nil,
        todayPLPct: Double? = nil,
        twValue: Double? = nil,
        twTodayPL: Double? = nil,
        usValue: Double? = nil,
        usTodayPL: Double? = nil,
        updatedAt: Date
    ) {
        self.netWorthTWD = netWorthTWD
        self.netWorthUSD = netWorthUSD
        self.todayPLTWD = todayPLTWD
        self.todayPLPct = todayPLPct
        self.twValue = twValue
        self.twTodayPL = twTodayPL
        self.usValue = usValue
        self.usTodayPL = usTodayPL
        self.updatedAt = updatedAt
    }
}

/// Read/write the widget snapshot via the shared App Group. The group ID must
/// match the `com.apple.security.application-groups` entitlement on BOTH the
/// app and the widget extension.
public enum WidgetSharedStore {
    public static let appGroup = "group.com.aistockstudio.app"
    private static let key = "portfolio.widget.snapshot"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    /// Called by the app after an overview refresh. Persists the snapshot and
    /// nudges WidgetKit to re-render.
    public static func write(_ data: PortfolioWidgetData) {
        guard let defaults, let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Called by the widget's timeline provider. Nil until the app writes once.
    public static func read() -> PortfolioWidgetData? {
        guard let defaults, let raw = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PortfolioWidgetData.self, from: raw)
    }
}
