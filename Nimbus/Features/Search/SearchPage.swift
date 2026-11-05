import SwiftUI

// Search is a destination of its own, as in Music; its field sits atop the sidebar on every page.
struct SearchPage: View {
    let model: AppModel

    @State private var linkFailed = false
    @Environment(\.navigator) private var navigator

    private var controls: SearchControls { model.searchControls }

    /// A pasted soundcloud.com address opens what it names rather than searching for its text.
    private var link: URL? { SoundCloudLink.url(in: controls.query) }

    var body: some View {
        Group {
            if controls.isBlank {
                GenreGridView { recentSearches }
            } else if let link {
                linkHint(link)
            } else {
                SearchResultsView(model: model)
                    .environment(\.navigator, Navigator { [controls, navigator] value in
                        controls.remember(controls.query)
                        navigator.open(value)
                    })
            }
        }
        // The genre grid takes no focus when clicked, so it hands the keyboard back itself.
        .simultaneousGesture(TapGesture().onEnded(ShellSearchField.endEditing))
        .onChange(of: controls.query) { _, text in
            linkFailed = false
            if SoundCloudLink.url(in: text) == nil { model.library.search.run(text) }
        }
        .onChange(of: controls.submits) { _, _ in
            if let link { open(link) }
        }
    }

    @ViewBuilder
    private var recentSearches: some View {
        if !controls.recents.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent Searches").font(.title2).bold()
                Spacer()
                Button("Clear") { controls.clearRecents() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(controls.recents, id: \.self) { text in
                        Button(text) {
                            controls.query = text
                            controls.remember(text)
                        }
                        .glassButton()
                    }
                }
            }
            .scrollIndicators(.never)
            .padding(.bottom, 12)
        }
    }

    private func linkHint(_ link: URL) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "link").font(.system(size: 22)).foregroundStyle(.tertiary)
            Text(linkFailed ? "Couldn't open this link" : "Press Return to open this link")
                .font(.system(size: 13, weight: .medium))
            if linkFailed {
                Button("Open in Browser") { NSWorkspace.shared.open(link) }
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func open(_ link: URL) {
        Task {
            guard let item = await SoundCloudLink.resolve(link, api: model.api) else {
                linkFailed = true
                return
            }
            navigator.open(item)
        }
    }
}
