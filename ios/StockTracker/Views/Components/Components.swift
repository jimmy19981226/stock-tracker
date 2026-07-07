import SwiftUI

extension View {
    /// Stocks-app-style rolling-digit transition: when `value` changes, digits
    /// roll up on an increase and down on a decrease. Attach to a Text whose
    /// string is derived from `value`.
    func rollingNumber(_ value: Double?) -> some View {
        contentTransition(.numericText(value: value ?? 0))
            .animation(.snappy(duration: 0.5), value: value)
    }
}

/// A solid green/red price pill (Robinhood-style) used on rows and headers.
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
                    .rollingNumber(value)
            }
            if let pct {
                Text(Fmt.pct(pct))
                    .rollingNumber(pct)
            }
        }
        .font(.system(.subheadline, design: .rounded).weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color == Theme.mutedText ? Theme.cardElevated : color)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(.snappy(duration: 0.5), value: color)
    }
}

/// Plain colored change line, e.g. "+NT$12,345 (+1.23%) Today".
struct ChangeLine: View {
    let value: Double?
    let pct: Double?
    var currency: String = ""
    var suffix: String = "Today"

    var body: some View {
        let color = Theme.pl(value ?? pct)
        HStack(spacing: 5) {
            Image(systemName: (value ?? pct ?? 0) >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                .font(.system(size: 10, weight: .bold))
            if let value {
                Text(Fmt.signedMoney(value, currency: currency))
                    .rollingNumber(value)
            }
            if let pct {
                Text("(\(Fmt.pct(pct)))")
                    .rollingNumber(pct)
            }
            if !suffix.isEmpty {
                Text(suffix).foregroundStyle(Theme.secondaryText)
            }
        }
        .font(.system(.subheadline, design: .rounded).weight(.semibold))
        .foregroundStyle(color)
        .animation(.snappy(duration: 0.5), value: color)
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
            .font(.system(size: size * 0.30, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.primaryText)
            .frame(width: size, height: size)
            .background(Theme.cardElevated)
            .clipShape(Circle())
    }
}

/// Centered empty-state placeholder with a soft accent icon backdrop.
struct EmptyState: View {
    let icon: String
    let title: String
    var message: String = ""

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.10))
                    .frame(width: 72, height: 72)
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.accent)
            }
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(Theme.primaryText)
                if !message.isEmpty {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

/// Flat text tabs with an accent underline on the selected one — replaces the
/// stock segmented control to match the dark theme.
struct UnderlineTabs<T: Hashable>: View {
    let tabs: [(value: T, label: String)]
    @Binding var selection: T
    var font: Font = .system(.subheadline, design: .rounded).weight(.bold)

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { _, tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selection = tab.value }
                } label: {
                    VStack(spacing: 8) {
                        Text(tab.label)
                            .font(font)
                            .foregroundStyle(selection == tab.value ? Theme.primaryText : Theme.mutedText)
                        Capsule()
                            .fill(selection == tab.value ? Theme.accent : .clear)
                            .frame(height: 3)
                            .padding(.horizontal, 14)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
        // A light tick when the selected tab changes, like the Stocks app.
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Full-width green primary action button (bottom CTA on forms).
struct PrimaryButton: View {
    let title: String
    var disabled = false
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().tint(.black)
                } else {
                    Text(title)
                        .font(.system(.body, design: .rounded).weight(.bold))
                }
            }
            .foregroundStyle(disabled ? Theme.mutedText : .black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(disabled ? Theme.cardElevated : Theme.accent)
            .clipShape(Capsule())
        }
        .disabled(disabled || busy)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.bg.opacity(0.94))
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

/// Floating tooltip shown while scrubbing a chart with a finger: the date at
/// the touch point and the series value there.
struct ChartScrubTip: View {
    let date: Date
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, format: .dateTime.year().month(.abbreviated).day())
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText)
            Text(value)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(Theme.primaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.cardElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }
}
