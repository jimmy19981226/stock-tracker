import SwiftUI

/// Launch splash — the brand glyph on the hero field, shown while `AuthStore`
/// restores the session. It uses the hero gradient rather than the ground so
/// the first frame is the same dark field the net-worth card lands on.
struct SplashView: View {
    @State private var appear = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.heroTop, Theme.heroBottom],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: Theme.Space.m) {
                Text("✦")
                    .font(.system(size: 46))
                    .foregroundStyle(Theme.heroText)
                    .scaleEffect(appear ? 1 : 0.7)
                    .opacity(appear ? 1 : 0)
                Text("AI Stock Studio")
                    .font(Theme.Typo.title)
                    .foregroundStyle(Theme.heroText)
                    .opacity(appear ? 1 : 0)
            }

            VStack {
                Spacer()
                Text("Version \(AppConfig.versionDisplay)")
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.heroLabel)
                    .opacity(appear ? 1 : 0)
                    .padding(.bottom, 28)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.6)) { appear = true }
        }
    }
}
