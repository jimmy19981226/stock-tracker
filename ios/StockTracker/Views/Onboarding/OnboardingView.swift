import SwiftUI

/// The pre-sign-in page. Brand hero + value props, a "Continue with Google"
/// button, and a guest fallback so the app is usable before Google OAuth is set up.
struct OnboardingView: View {
    @EnvironmentObject private var auth: AuthStore

    var body: some View {
        ZStack {
            Theme.backgroundGradient.ignoresSafeArea()
            LinearGradient(colors: [Theme.accent.opacity(0.25), .clear],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                BrandMark(stroke: Theme.accent)
                    .frame(width: 84, height: 84)
                Text("AI Stock Studio")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primaryText)
                    .padding(.top, 16)
                Text("Your TW & US portfolio, live —\nwith an AI analyst in your pocket.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 14) {
                    feature("chart.line.uptrend.xyaxis", "Live holdings, P&L and dividends")
                    feature("sparkle", "Ask AI about your portfolio")
                    feature("lock.shield", "Signed in with your Google account")
                }
                .padding(.top, 36)
                .padding(.horizontal, 8)

                Spacer()

                if let error = auth.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.negative)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 8)
                }

                Button {
                    Task { await auth.signInWithGoogle() }
                } label: {
                    HStack(spacing: 10) {
                        if auth.isSigningIn {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: "g.circle.fill")
                        }
                        Text("Continue with Google")
                            .font(.system(.body, design: .rounded).weight(.bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.accent)
                    .foregroundStyle(.black)
                    .clipShape(Capsule())
                }
                .disabled(auth.isSigningIn)

                Button("Continue without signing in") {
                    auth.continueAsGuest()
                }
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 14)
            }
            .padding(24)
        }
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
        }
    }
}
