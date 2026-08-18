import SwiftUI

/// The sign-in gate: a full-bleed hero field, the product name at 40pt, one
/// sentence of what it is, and two equally-weighted ways in. Nothing else —
/// a feature list here would be read by nobody and would push the buttons
/// below the fold on a small phone.
struct OnboardingView: View {
    @EnvironmentObject private var auth: AuthStore

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.heroTop, Theme.heroBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                Text("✦")
                    .font(.system(size: 46))
                    .foregroundStyle(Theme.heroText)
                Text("AI Stock Studio")
                    .font(Theme.Typo.signIn)
                    .foregroundStyle(Theme.heroText)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                Text("Taiwan and US portfolios in one net worth. Live prices, dividends, FIFO P/L, and an assistant that reads your holdings.")
                    .font(Theme.Typo.body)
                    .foregroundStyle(Theme.heroLabel)
                    .frame(maxWidth: 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                if let error = auth.errorMessage {
                    Text(error)
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.heroLabel)
                        .padding(.bottom, Theme.Space.s)
                }

                Button {
                    Task { await auth.signInWithGoogle() }
                } label: {
                    Group {
                        if auth.isSigningIn {
                            ProgressView().tint(Theme.heroBottom)
                        } else {
                            Text("Continue with Google")
                        }
                    }
                    .font(Theme.Typo.button)
                    .foregroundStyle(Theme.heroBottom)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(auth.isSigningIn)

                Button { auth.continueAsGuest() } label: {
                    Text("Continue as guest")
                        .font(Theme.Typo.button)
                        .foregroundStyle(Theme.heroText)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, Theme.Space.m)

                Text("Your trades stay on your own backend. No broker login, no analytics.")
                    .font(Theme.Typo.micro)
                    .foregroundStyle(Theme.heroLabel)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .padding(.top, Theme.Space.l)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 46)
        }
    }
}
