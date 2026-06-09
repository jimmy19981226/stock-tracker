import SwiftUI

/// A coloured P&L pill (green up / red down) used on cards and rows.
struct PLBadge: View {
    let value: Double?
    let pct: Double?
    var currency: String = ""
    var compact: Bool = false

    var body: some View {
        let color = Theme.pl(value ?? pct)
        HStack(spacing: 4) {
            if let value, !compact {
                Text(Fmt.signedMoney(value, currency: currency))
            }
            if let pct {
                Text(Fmt.pct(pct))
            }
        }
        .font(.system(.subheadline, design: .rounded).weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.14))
        .clipShape(Capsule())
    }
}

/// A small labelled statistic, stacked label-over-value.
struct StatBlock: View {
    let label: String
    let value: String
    var valueColor: Color = Theme.primaryText
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.mutedText)
                .tracking(0.4)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(valueColor)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

/// Section heading with optional trailing accessory.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(Theme.primaryText)
            Spacer()
            trailing
        }
    }
}

/// A round ticker "avatar" — first letters of the symbol on an accent chip.
struct TickerBadge: View {
    let ticker: String
    var size: CGFloat = 40

    private var initials: String {
        let cleaned = ticker.split(separator: ".").first.map(String.init) ?? ticker
        return String(cleaned.prefix(cleaned.count > 4 ? 4 : cleaned.count)).uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(Theme.accent.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

/// Centered empty-state placeholder.
struct EmptyState: View {
    let icon: String
    let title: String
    var message: String = ""

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.mutedText)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.secondaryText)
            if !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.mutedText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

/// Inline error banner.
struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.negative)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
            Spacer()
            if let retry {
                Button("Retry", action: retry)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(12)
        .background(Theme.negative.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
