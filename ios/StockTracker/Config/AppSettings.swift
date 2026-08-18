import Combine
import SwiftUI

/// Appearance the user picked in Settings. `.system` follows iOS.
enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

/// Which direction is "up". Taiwanese charts colour a gain red and a loss
/// green — the opposite of the US convention. This is a *display* setting
/// only: it never changes a sign, only which token `Theme.pl(_:)` returns,
/// which is why nothing may hard-code green/red at a call site.
enum PLConvention: String, CaseIterable, Identifiable {
    case us, tw
    var id: String { rawValue }
    var label: String { self == .us ? "US · green up" : "TW · red up" }
}

/// The handful of user preferences the whole UI reads. One observable object
/// rather than scattered `@AppStorage` properties, because `Theme` — a plain
/// enum with no view identity — has to be able to read the P/L convention and
/// the whole tree has to repaint when it changes.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("appearance") var appearanceRaw: String = Appearance.system.rawValue {
        willSet { objectWillChange.send() }
    }
    @AppStorage("plConvention") var plConventionRaw: String = PLConvention.us.rawValue {
        willSet {
            // Theme.pl(_:) reads the mirror below, not UserDefaults, so it stays
            // cheap enough to call from inside a body.
            AppSettings.plConvention = PLConvention(rawValue: newValue) ?? .us
            objectWillChange.send()
        }
    }
    @AppStorage("showReasoning") var showReasoning: Bool = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("backgroundGeneration") var backgroundGeneration: Bool = true {
        willSet { objectWillChange.send() }
    }

    var appearance: Appearance {
        get { Appearance(rawValue: appearanceRaw) ?? .system }
        set { appearanceRaw = newValue.rawValue }
    }
    var plConvention: PLConvention {
        get { PLConvention(rawValue: plConventionRaw) ?? .us }
        set { plConventionRaw = newValue.rawValue }
    }

    /// Non-isolated mirror of `plConvention` for `Theme.pl(_:)`.
    nonisolated(unsafe) fileprivate static var plConvention: PLConvention = .us

    private init() {
        let raw = UserDefaults.standard.string(forKey: "plConvention") ?? PLConvention.us.rawValue
        AppSettings.plConvention = PLConvention(rawValue: raw) ?? .us
    }
}

extension Theme {
    /// The live P/L convention, read by `Theme.pl(_:)`.
    static var plConvention: PLConvention { AppSettings.plConvention }
}
