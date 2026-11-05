import AppKit
import SwiftUI

@MainActor
@Observable
final class SearchSuggestions {
    private(set) var items: [String] = []
    var selected: Int?

    @ObservationIgnored private let api: SoundCloudAPI
    @ObservationIgnored private var task: Task<Void, Never>?

    init(api: SoundCloudAPI) {
        self.api = api
    }

    var current: String? {
        selected.flatMap { items.indices.contains($0) ? items[$0] : nil }
    }

    func update(for text: String) {
        task?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, SoundCloudLink.url(in: query) == nil else {
            clear()
            return
        }
        let api = api
        task = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let page = try? await api.searchSuggestions(query), !Task.isCancelled else { return }
            items = page.collection.map(\.query).filter { $0.caseInsensitiveCompare(query) != .orderedSame }
            selected = nil
        }
    }

    // Up from the first row goes back to what was typed.
    func move(_ step: Int) {
        guard !items.isEmpty else { return }
        guard let selected else {
            self.selected = step > 0 ? 0 : items.count - 1
            return
        }
        let next = selected + step
        self.selected = items.indices.contains(next) ? next : (next < 0 ? nil : selected)
    }

    func clear() {
        task?.cancel()
        items = []
        selected = nil
    }
}

// A borderless child window under the field, the way AppKit's own completion lists sit outside the window's bounds.
@MainActor
final class SuggestionsPopup {
    private let panel = SuggestionsPanel()
    private let suggestions: SearchSuggestions
    private weak var field: NSTextField?

    private static let rowHeight: CGFloat = 28
    private static let inset: CGFloat = 6
    private static let minWidth: CGFloat = 300

    init(suggestions: SearchSuggestions, field: NSTextField, pick: @escaping (String) -> Void) {
        self.suggestions = suggestions
        self.field = field
        panel.contentView = FirstClickHostingView(rootView: SuggestionsList(suggestions: suggestions, pick: pick)
            .tint(.scOrange))
        follow()
    }

    private func follow() {
        withObservationTracking {
            place(rows: suggestions.items.count)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func place(rows: Int) {
        guard rows > 0, let field, let window = field.window,
              (window.firstResponder as? NSTextView)?.delegate === field else {
            hide()
            return
        }
        let anchor = window.convertToScreen(field.convert(field.bounds, to: nil))
        let height = CGFloat(rows) * Self.rowHeight + Self.inset * 2
        panel.setFrame(NSRect(x: anchor.minX, y: anchor.minY - 6 - height,
                              width: max(anchor.width, Self.minWidth), height: height), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

// Never key: typing stays in the field while the list is shown and clicked.
private final class SuggestionsPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// The panel is never key, so without this the first click on a row would only be spent on the window.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct SuggestionsList: View {
    let suggestions: SearchSuggestions
    let pick: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.items.enumerated()), id: \.offset) { index, text in
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(text).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(suggestions.selected == index ? 0.1 : 0))
                }
                .contentShape(Rectangle())
                .onTapGesture { pick(text) }
                .onHover { if $0 { suggestions.selected = index } }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}
