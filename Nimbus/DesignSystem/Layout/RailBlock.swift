import SwiftUI

/// A titled block: a quiet uppercase label with an optional control opposite it, the way the site
/// heads every panel in this column.
struct RailBlock<Content: View>: View {
    let title: String
    var action: String?
    var run: (() -> Void)?
    var destination: (any Hashable)?
    @ViewBuilder let content: Content

    init(title: String, action: String? = nil, destination: (any Hashable)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.action = action
        self.destination = destination
        self.content = content()
    }

    init(title: String, action: String?, run: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.action = action
        self.run = run
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if let action {
                    if let destination {
                        NavButton(value: destination) { actionLabel(action) }
                    } else if let run {
                        Button(action: run) { actionLabel(action) }.buttonStyle(.plain)
                    }
                }
            }
            content
        }
    }

    private func actionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
    }
}
