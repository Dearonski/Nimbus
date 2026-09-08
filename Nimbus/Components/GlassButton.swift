import SwiftUI

/// The app's one button look, matching `GlassTabBar`: Liquid Glass where the system has it, a
/// material capsule on macOS 15, our deployment floor. Every control with a background goes
/// through this — the mix of `.bordered` and `.borderedProminent` it replaces drew a different
/// shape on every page.
enum GlassButtonKind {
    /// The default: a quiet, untinted glass capsule.
    case neutral
    /// The one action a screen exists for — tinted, at most one per row.
    case prominent
    /// Glyph only, sized square so a row of them reads as one group.
    case icon
}

/// One height for everything that sits on a control row — buttons, the tab bar, a filter field.
/// Derived in one place so a row cannot end up a point and a half out of alignment, which is
/// exactly what happened while the tab bar sized itself from its own padding.
enum GlassMetrics {
    static func height(_ size: ControlSize) -> CGFloat {
        switch size {
        case .mini: 22
        case .small: 26
        case .large, .extraLarge: 34
        default: 30
        }
    }

    /// Inset of the segments inside the tab bar's own capsule.
    static let barPadding: CGFloat = 3
}

extension View {
    func glassButton(_ kind: GlassButtonKind = .neutral) -> some View {
        buttonStyle(GlassButtonStyle(kind: kind))
    }

    /// Wraps a row of glass buttons so the system merges their effects instead of compositing each
    /// capsule on its own — what makes neighbouring controls read as one control strip.
    func glassButtonRow(spacing: CGFloat = 8) -> some View {
        modifier(GlassRow(spacing: spacing))
    }
}

private struct GlassRow: ViewModifier {
    let spacing: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Built on `glassEffect` rather than the system's `.glass` button style: that style dyes the
/// capsule with the environment's tint, and this app tints everything scOrange — every secondary
/// control came out a bright orange slab. Here the accent belongs to `prominent` alone.
struct GlassButtonStyle: ButtonStyle {
    var kind: GlassButtonKind = .neutral

    func makeBody(configuration: Configuration) -> some View {
        Look(kind: kind, configuration: configuration)
    }

    /// Named around the protocol: `Body` is `ButtonStyle`'s own associated type.
    private struct Look: View {
        let kind: GlassButtonKind
        let configuration: Configuration

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @State private var hovering = false

        private var isProminent: Bool { kind == .prominent }

        private var height: CGFloat { GlassMetrics.height(controlSize) }

        private var padding: CGFloat {
            switch controlSize {
            case .mini, .small: 10
            case .large, .extraLarge: 16
            default: 13
            }
        }

        private var fontSize: CGFloat {
            switch controlSize {
            case .mini, .small: 12
            default: 13
            }
        }

        var body: some View {
            label
                .brightness(configuration.isPressed ? -0.05 : 0)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Capsule())
                .animation(.snappy(duration: 0.14), value: configuration.isPressed)
                .animation(.snappy(duration: 0.14), value: hovering)
                .onHover { hovering = $0 }
        }

        @ViewBuilder
        private var label: some View {
            let sized = configuration.label
                .font(.system(size: fontSize, weight: isProminent ? .semibold : .regular))
                .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, kind == .icon ? 0 : padding)
                .frame(width: kind == .icon ? height : nil, height: height)

            if #available(macOS 26.0, *) {
                sized.glassEffect(isProminent ? .regular.tint(.scOrange) : .regular, in: .capsule)
            } else {
                sized
                    .background {
                        if isProminent {
                            Capsule().fill(.tint)
                        } else {
                            Capsule().fill(.ultraThinMaterial)
                            Capsule().fill(.primary.opacity(hovering ? 0.09 : 0.05))
                        }
                    }
                    .overlay {
                        if !isProminent {
                            Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                        }
                    }
                    .clipShape(Capsule())
            }
        }
    }
}

#if DEBUG
#Preview("Buttons") {
    VStack(alignment: .leading, spacing: 26) {
        ForEach([ControlSize.large, .regular, .small], id: \.self) { size in
            VStack(alignment: .leading, spacing: 8) {
                Text(String(describing: size))
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button { } label: { Label("Play", systemImage: "play.fill") }
                        .glassButton(.prominent)
                    Button { } label: { Label("Station", systemImage: "dot.radiowaves.left.and.right") }
                        .glassButton()
                    Button { } label: { Label("Share", systemImage: "square.and.arrow.up") }
                        .glassButton()
                    Button { } label: { Image(systemName: "envelope") }
                        .glassButton(.icon)
                    Button { } label: { Image(systemName: "ellipsis") }
                        .glassButton(.icon)
                    Button { } label: { Text("Disabled") }
                        .glassButton()
                        .disabled(true)
                }
                .controlSize(size)
            }
        }
    }
    .padding(28)
    .frame(width: 720)
    .background(SCGradient(index: 3).opacity(0.5))
    .tint(.scOrange)
}
#endif
