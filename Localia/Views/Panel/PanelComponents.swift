import SwiftUI

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
    var body: some View { Divider().opacity(0.4).padding(.leading, 54) }
}

/// Collapsible card with a chevron header (ported from ClaudeCockpit), with an optional value on the right.
struct DisclosureCard<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    var value: String? = nil
    var valueColor: Color? = nil
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
                    Text(title).font(.system(size: 14, weight: .semibold)).layoutPriority(1)
                    Spacer(minLength: 8)
                    if let value {
                        // A long value (a model name) truncates; the title keeps its width.
                        Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(valueColor ?? .secondary)
                            .monospacedDigit().lineLimit(1).truncationMode(.tail)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
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

/// Fill bar split by tick marks into equal segments, like Juicy's battery bar.
struct SegmentedBar: View {
    /// 0…1.
    let fraction: Double
    let tint: Color
    var segments = 4

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(tint).frame(width: max(10, w * min(1, max(0, fraction))))
                ForEach(1..<segments, id: \.self) { i in
                    Rectangle()
                        .fill(Color.black.opacity(0.28))
                        .frame(width: 1, height: geo.size.height)
                        .offset(x: w * CGFloat(i) / CGFloat(segments))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityValue(Text(fraction.formatted(.percent.precision(.fractionLength(0)).locale(Fmt.appLocale))))
    }
}

/// A switch drawn in SwiftUI (no NSSwitch, so the tint is honoured and it renders in snapshots), sized
/// like the native one by default, in the spirit of a "Low Power Mode" toggle.
struct PillToggleStyle: ToggleStyle {
    var onColor: Color = Theme.accent
    var width: CGFloat = 40
    var height: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? onColor : Theme.track)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: width, height: height)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: configuration.isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // VoiceOver sees a standard switch with the toggle's label.
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// A thin teal progress bar (a system bar turns grey whenever its window is not key). `value` nil: the bar
/// shows an empty track.
struct TealProgressBar: View {
    let value: Double?
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                if let value {
                    Capsule().fill(Theme.accent)
                        .frame(width: max(height, geo.size.width * min(1, max(0, value))))
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(Text(String(localized: "Progress")))
        .accessibilityValue(Text(value.map { $0.formatted(.percent.precision(.fractionLength(0)).locale(Fmt.appLocale)) } ?? ""))
    }
}

/// A word with an SF Symbol in a soft capsule of its colour: "Fast", "Memory is tight".
struct WordPill: View {
    let text: String
    var symbol: String? = nil
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Simple mode's main button: full width, filled teal, generous height.
struct PrimaryWideButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WideLabel(configuration: configuration)
    }

    private struct WideLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 38)
                .foregroundStyle(Theme.onAccent)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(configuration.isPressed ? 0.14 : (hovering && isEnabled ? 0.06 : 0))))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}
