import SwiftUI

@main
struct StockTrackerApp: App {
    @StateObject private var store = PortfolioStore()
    @StateObject private var auth = AuthStore()
    @StateObject private var settings = AppSettings.shared
    @StateObject private var toasts = ToastCenter.shared
    @State private var showSplash = true

    init() { Theme.registerFonts() }

    var body: some Scene {
        WindowGroup {
            ZStack {
                switch auth.state {
                case .signedIn:
                    RootView()
                        .environmentObject(store)
                case .signedOut, .loading:
                    OnboardingView()
                }

                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .environmentObject(auth)
            .environmentObject(settings)
            .environmentObject(toasts)
            .tint(Theme.accent)
            // The one place the Appearance setting is applied. `nil` for
            // .system hands the decision back to iOS.
            .preferredColorScheme(settings.appearance.colorScheme)
            .task {
                if ProcessInfo.processInfo.environment["UITEST_GUEST"] == "1" {
                    auth.continueAsGuest()
                }
                // Hold the splash briefly while the session restores.
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation(.easeOut(duration: 0.35)) { showSplash = false }
            }
        }
    }
}
