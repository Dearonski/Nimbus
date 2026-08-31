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

            if isBlank {
                GenreGridView()
            } else {
                SearchResultsView(model: model)
            }
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
        .background(Color.primary.opacity(0.07), in: Capsule())
        .padding(.horizontal, gutter)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }
}
