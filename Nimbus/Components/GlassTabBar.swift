import SwiftUI

/// A compact segmented control that sizes to its labels instead of stretching across the column,
/// the way `.pickerStyle(.segmented)` does. Liquid Glass where the system has it; on macOS 15,
/// still our deployment floor, it falls back to a material capsule that reads the same way.
struct GlassTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    let title: (Tab) -> String
    /// Set to show a glyph instead of the label — the same bar then serves as a view switcher,
    /// which is what `.pickerStyle(.segmented)` used to do in a shape of its own.
    var icon: ((Tab) -> String)? = nil
    @Binding var selection: Tab

    @Environment(\.controlSize) private var controlSize

    @Namespace private var highlight
    @State private var hovered: Tab?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let isSelected = tab == selection
                Button {
                    // A touch of bounce: the pill is meant to slide like liquid, not cut.
                    withAnimation(.snappy(duration: 0.3, extraBounce: 0.18)) { selection = tab }
                } label: {
                    label(for: tab)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.scOrange) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, icon == nil ? 14 : 10)
                        // Height comes from the shared metric rather than from padding, so the bar
                        // lines up with the buttons beside it at every control size.
                        .frame(height: GlassMetrics.height(controlSize) - GlassMetrics.barPadding * 2)
                        .background {
                            if isSelected {
                                selectionPill
                            } else if hovered == tab {
                                Capsule().fill(.primary.opacity(0.09))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.snappy(duration: 0.14)) { hovered = hovering ? tab : nil }
                }
            }
        }
        .padding(GlassMetrics.barPadding)
        .glassCapsule()
    }

    /// The selection is a second piece of glass riding on the bar, and the accent lives in the
    /// label — the same division the sidebar uses. An orange capsule was tried and read as a
    /// button rather than a state, and tinting the glass itself comes out muddy brown on a dark page.
    @ViewBuilder
    private var selectionPill: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: .capsule)
                // Glass on glass barely separates; a hair of light lifts the selected segment
                // without turning it into a filled button.
                .overlay { Capsule().fill(.primary.opacity(0.07)) }
                .matchedGeometryEffect(id: "selection", in: highlight)
        } else {
            Capsule()
                .fill(.primary.opacity(0.16))
                .matchedGeometryEffect(id: "selection", in: highlight)
        }
    }

    @ViewBuilder
    private func label(for tab: Tab) -> some View {
        if let icon {
            Image(systemName: icon(tab)).frame(width: 20)
        } else {
            Text(title(tab))
        }
    }
}

extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.ultraThinMaterial, in: Capsule())
        }
    }
}

#if DEBUG
private enum PreviewTab: String, CaseIterable, Identifiable {
    case all = "All", popular = "Popular", tracks = "Tracks", albums = "Albums"
    var id: String { rawValue }
}

private enum PreviewLayout: String, CaseIterable, Identifiable {
    case list, grid
    var id: String { rawValue }
    var systemImage: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

#Preview("Tab bar") {
    VStack(alignment: .leading, spacing: 22) {
        GlassTabBar(tabs: PreviewTab.allCases, title: \.rawValue, selection: .constant(.all))
        GlassTabBar(tabs: PreviewTab.allCases, title: \.rawValue, selection: .constant(.tracks))
        GlassTabBar(tabs: PreviewLayout.allCases, title: \.rawValue,
                    icon: \.systemImage, selection: .constant(.grid))
    }
    .padding(30)
    .frame(width: 560)
    .background(SCGradient(index: 3).opacity(0.55))
    .tint(.scOrange)
}
#endif
