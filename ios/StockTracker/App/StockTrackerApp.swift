import SwiftUI

@main
struct StockTrackerApp: App {
    @StateObject private var store = PortfolioStore()
    @StateObject private var auth = AuthStore()
    @State private var showSplash = true

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
            .tint(Theme.accent)
            .preferredColorScheme(.dark)
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
