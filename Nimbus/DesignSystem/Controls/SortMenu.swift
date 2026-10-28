import SwiftUI

/// A list's sort order as a glass button: the current order's name, or an icon where room is short.
struct SortMenu<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String
    var iconOnly = false

    var body: some View {
        Menu {
            // Inline, or the picker's own label becomes a "Sort ▸" submenu you have to open first.
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { Text(title($0)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            if iconOnly {
                Image(systemName: "arrow.up.arrow.down")
            } else {
                HStack(spacing: 6) {
                    Text(title(selection))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                }
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .glassButton(iconOnly ? .icon : .neutral)
        .fixedSize()
    }
}
