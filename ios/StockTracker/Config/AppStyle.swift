import SwiftUI

/// User-selectable accent style. Each is hand-picked to read well on the pure-
/// black theme; P&L colors (green gain / red loss) never change — the style
/// recolors the brand accent: tabs, buttons, icons, highlights.
enum AppStyle: String, CaseIterable, Identifiable {
    case emerald
    case ocean
    case violet
    case sunset
    case rose
    case gold

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .emerald: return "Emerald"
        case .ocean: return "Ocean"
        case .violet: return "Violet"
        case .sunset: return "Sunset"
        case .rose: return "Rose"
        case .gold: return "Gold"
        }
    }

    var accent: Color {
        switch self {
        case .emerald: return Color(red: 0.00, green: 0.78, blue: 0.02)   // #00C805
        case .ocean: return Color(red: 0.04, green: 0.52, blue: 1.00)     // #0A84FF
        case .violet: return Color(red: 0.75, green: 0.35, blue: 0.95)    // #BF5AF2
        case .sunset: return Color(red: 1.00, green: 0.62, blue: 0.04)    // #FF9F0A
        case .rose: return Color(red: 1.00, green: 0.22, blue: 0.37)      // #FF375F
        case .gold: return Color(red: 1.00, green: 0.84, blue: 0.04)      // #FFD60A
        }
    }

    private static let key = "ui.style"

    static var current: AppStyle {
        get {
            AppStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .emerald
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
