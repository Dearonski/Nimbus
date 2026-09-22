import SwiftUI

/// Search is a destination of its own rather than a toolbar field. The window toolbar sits outside
/// the content area, so an inspector can't resize anything living in it — Music puts search in the
/// sidebar for the same reason.
struct SearchPage: View {
    let model: AppModel

    @State private var query = ""
    @FocusState private var focused: Bool

    private var isBlank: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            field

            Group {
                if isBlank {
                    GenreGridView()
                } else {
                    SearchResultsView(model: model)
                }
            }
            // Results are a List and take focus themselves; the genre grid does not, so clicking
            // it would otherwise leave the caret in the field.
            .simultaneousGesture(TapGesture().onEnded { focused = false })
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, text in model.library.search(text) }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search SoundCloud", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                // Typing owns the space bar while the field has focus, so there has to be a way
                // out of it that does not involve the mouse. Esc keeps the query, the results
                // stay on screen, and the transport gets its shortcut back.
                .onSubmit { focused = false }
                .onKeyPress(.escape) {
                    focused = false
                    return .handled
                }
                .reportsTyping(focused, to: model)
                .onChange(of: model.focusFieldRequest) { _, _ in focused = true }

            if !query.isEmpty {
                Button {
                    query = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassCapsule()
        .padding(.horizontal, gutter)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }
}
