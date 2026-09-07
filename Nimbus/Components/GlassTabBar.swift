import SwiftUI

/// A compact segmented control that sizes to its labels instead of stretching across the column,
/// the way `.pickerStyle(.segmented)` does. Liquid Glass where the system has it; on macOS 15,
/// still our deployment floor, it falls back to a material capsule that reads the same way.
struct GlassTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    let title: (Tab) -> String
    @Binding var selection: Tab

    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let isSelected = tab == selection
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = tab }
                } label: {
                    Text(title(tab))
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background {
                            if isSelected {
                                // A light pill over the glass, the way the system draws selection
                                // in Liquid Glass. Tinting it instead turned muddy brown on a dark
                                // background and read as a disabled segment.
                                Capsule()
                                    .fill(.primary.opacity(0.16))
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassCapsule()
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
