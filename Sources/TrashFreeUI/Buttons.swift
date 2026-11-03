import AppKit
import SwiftUI

/// Every push button in the app: one height, one radius, one weight. `primary` is ink
/// on canvas and is used at most once per region; `secondary` is a quiet fill that still
/// reads as a control at rest.
struct ActionButton: View {
    enum Kind {
        case primary, secondary, destructive
    }

    let title: String
    var kind: Kind = .secondary
    var systemImage: String?
    var width: CGFloat?
    let action: () -> Void

    static let height: CGFloat = 26

    var body: some View {
        Button(role: kind == .destructive ? .destructive : nil, action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12, weight: .medium))
                }
                Text(title).lineLimit(1)
            }
            .font(Theme.Font.control)
            .padding(.horizontal, 12)
            .frame(width: width, height: Self.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(ActionButtonStyle(kind: kind))
        .accessibilityLabel(title)
    }
}

struct ActionButtonStyle: ButtonStyle {
    let kind: ActionButton.Kind
    var shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    /// Off for the halves of a split button, which would otherwise shrink apart.
    var scalesWhenPressed = true

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, kind: kind, shape: shape, scales: scalesWhenPressed)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let kind: ActionButton.Kind
        let shape: RoundedRectangle
        let scales: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .foregroundColor(foreground)
                .background(shape.fill(fill))
                .overlay(shape.fill(hovering && isEnabled && !pressed ? Theme.hoverWash(onInk: kind == .primary) : .clear))
                .clipShape(shape)
                .scaleEffect(pressed && scales && !reduceMotion ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
                .animation(Theme.Motion.hover, value: hovering)
                .animation(Theme.Motion.press, value: pressed)
        }

        private var foreground: Color {
            switch kind {
            case .primary: return Theme.primaryText
            case .secondary: return Theme.text
            case .destructive: return Theme.destructive
            }
        }

        private var fill: Color {
            switch kind {
            case .primary: return configuration.isPressed ? Theme.primaryPressed : Theme.primaryFill
            case .secondary, .destructive: return configuration.isPressed ? Theme.pressedFill : Theme.controlFill
            }
        }
    }
}

/// No fill at rest; a hover wash and a pressed fill. For toolbar chevrons, crumbs,
/// and list rows that act as buttons.
struct QuietButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundColor(Theme.text)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(configuration.isPressed ? Theme.pressedFill : hovering && isEnabled ? Theme.hoverFill : .clear))
                .opacity(isEnabled ? 1 : 0.35)
                .onHover { hovering = $0 }
                .animation(Theme.Motion.hover, value: hovering)
        }
    }
}

/// "Scan ▾" / "View ▾": the label runs the main action, the chevron opens a menu.
/// Both halves share one shape, so the pair reads as a single control.
struct SplitButton: View {
    let title: String
    var kind: ActionButton.Kind = .secondary
    let primary: () -> Void
    let entries: [MenuEntry]

    static let size = CGSize(width: 96, height: ActionButton.height)
    private static let arrowWidth: CGFloat = 24

    @State private var arrowHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: primary) {
                Text(title)
                    .font(Theme.Font.control)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ActionButtonStyle(kind: kind, shape: RoundedRectangle(cornerRadius: 0), scalesWhenPressed: false))
            .accessibilityLabel(title)

            Rectangle()
                .fill(kind == .primary ? Theme.primaryText.opacity(0.25) : Theme.hairline)
                .frame(width: 1)

            PopUpArrow(accessibilityLabel: "\(title) options", isOnInk: kind == .primary, entries: entries)
                .frame(width: Self.arrowWidth)
                .background(kind == .primary ? Theme.primaryFill : Theme.controlFill)
                .overlay(Rectangle().fill(arrowHovering ? Theme.hoverWash(onInk: kind == .primary) : .clear).allowsHitTesting(false))
                .onHover { arrowHovering = $0 }
                .animation(Theme.Motion.hover, value: arrowHovering)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
