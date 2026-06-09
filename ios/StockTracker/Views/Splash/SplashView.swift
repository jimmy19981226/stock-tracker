import SwiftUI

/// Animated launch splash — the brand mark on the app's blue gradient, shown
/// briefly while `AuthStore` restores the session, then it fades into the app.
struct SplashView: View {
    @State private var appear = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.54, blue: 0.98),
                         Color(red: 0.05, green: 0.16, blue: 0.42)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                BrandMark()
                    .frame(width: 92, height: 92)
                    .scaleEffect(appear ? 1 : 0.7)
                    .opacity(appear ? 1 : 0)

                Text("AI Stock Studio")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .opacity(appear ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.6)) { appear = true }
        }
    }
}

/// The rising-chart logo (same path as the app icon), drawn in SwiftUI.
struct BrandMark: View {
    var stroke: Color = .white

    private func point(_ x: CGFloat, _ y: CGFloat, in size: CGSize) -> CGPoint {
        CGPoint(x: x / 24 * size.width, y: y / 24 * size.height)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Path { path in
                    path.move(to: point(3, 18, in: size))
                    path.addLine(to: point(9, 12, in: size))
                    path.addLine(to: point(13, 16, in: size))
                    path.addLine(to: point(21, 6, in: size))
                }
                .stroke(stroke, style: StrokeStyle(lineWidth: size.width * 0.09,
                                                   lineCap: .round, lineJoin: .round))
                Circle()
                    .fill(stroke)
                    .frame(width: size.width * 0.13, height: size.width * 0.13)
                    .position(point(21, 6, in: size))
            }
        }
    }
}
