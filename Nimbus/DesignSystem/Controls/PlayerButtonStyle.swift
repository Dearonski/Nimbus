import SwiftUI

/// Transport buttons dip and dim on press — plain `.borderless` gives no press feedback at all, and
/// a custom style also has to dim the disabled state itself. It also sets the hit target: a bare
/// glyph is only clickable on its own strokes, which at 15pt is a target a few points wide.
struct PlayerButtonStyle: ButtonStyle {
    static let hitTarget: CGFloat = 32
    /// Gap between buttons in the actions row; the volume panel measures itself against it.
    static let actionSpacing: CGFloat = 4

    /// Play/pause opts out: its symbol replace is already a scale animation, and a second scale on
    /// release reads as the same animation playing twice.
    var animatesPress = true

    func makeBody(configuration: Configuration) -> some View {
        if animatesPress {
            PressableLabel(configuration: configuration)
        } else {
            FlatLabel(configuration: configuration)
        }
    }

    private struct PressableLabel: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration
        @State private var pressed = false

        var body: some View {
            configuration.label
                .frame(minWidth: PlayerButtonStyle.hitTarget, minHeight: PlayerButtonStyle.hitTarget)
                .contentShape(Rectangle())
                .scaleEffect(pressed ? 0.88 : 1)
                .opacity(isEnabled ? (pressed ? 0.55 : 1) : 0.3)
                // Driving an own state instead of `.animation(value: isPressed)` on the label: that
                // modifier re-runs every animation inside it on release.
                .onChange(of: configuration.isPressed) { _, isPressed in
                    withAnimation(.snappy(duration: 0.16)) { pressed = isPressed }
                }
        }
    }

    private struct FlatLabel: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration

        var body: some View {
            configuration.label
                .frame(minWidth: PlayerButtonStyle.hitTarget, minHeight: PlayerButtonStyle.hitTarget)
                .contentShape(Rectangle())
                .opacity(isEnabled ? (configuration.isPressed ? 0.5 : 1) : 0.3)
        }
    }
}
