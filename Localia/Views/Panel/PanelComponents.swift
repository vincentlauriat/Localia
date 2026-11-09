import SwiftUI

/// Settings-list row with a leading SF Symbol (ported from ClaudeCockpit).
struct ActionRow<Trailing: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .medium))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
    }
}

extension ActionRow where Trailing == EmptyView {
    init(icon: String, iconColor: Color, title: String, subtitle: String? = nil) {
        self.init(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// The chevron of a row that opens or reveals something: points right, down when `expanded`.
struct RowChevron: View {
    var expanded = false
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
    }
}

/// A full-width row button: highlights on hover and press, like a menu item.
struct PanelRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PanelRowButton(configuration: configuration)
    }

    private struct PanelRowButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : (hovering && isEnabled ? 0.05 : 0)))
                        .padding(.horizontal, 4))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

/// Hairline between rows of a card, inset past the icon column.
struct RowDivider: View {
    var body: some View { Divider().opacity(0.4).padding(.leading, 46) }
}

/// Collapsible card with a chevron header (ported from ClaudeCockpit), with an optional value on the right.
struct DisclosureCard<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    var value: String? = nil
    @Binding var expanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 22)
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if let value {
                        Text(value).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    RowChevron(expanded: expanded)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(spacing: 0) { content }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .card()
    }
}

/// "Label ……… value" row (ported from ClaudeCockpit).
struct InfoRow: View {
    let label: String
    let value: String
    var tint: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
        }
        .padding(.vertical, 6)
    }
}

/// Horizontal fill bar, like ClaudeCockpit's quota bar.
struct UsageBar: View {
    /// 0…1.
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(tint)
                    .frame(width: max(8, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityValue(Text(fraction.formatted(.percent.precision(.fractionLength(0)))))
    }
}

/// A large pill switch drawn in SwiftUI (no NSSwitch), in the spirit of a "Low Power Mode" toggle.
struct PillToggleStyle: ToggleStyle {
    var onColor: Color = Theme.local

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? onColor : Theme.track)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
                    .padding(3)
            }
            .frame(width: 54, height: 32)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: configuration.isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // VoiceOver sees a standard switch with the toggle's label.
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// Inline warning banner (ClaudeCockpit's `SourceBanner`, warning kind only).
struct WarningBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
            Text(message).font(.system(size: 11)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
