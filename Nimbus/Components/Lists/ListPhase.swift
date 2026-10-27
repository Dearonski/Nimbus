import SwiftUI

/// What an empty list is doing, decided in one place: each list used to ask its own way, and one of
/// them called itself empty while its first page was still on the way.
enum ListPhase: Equatable {
    /// Nothing yet, and nothing has said there is nothing: a first load is coming or under way.
    case loading
    case failed(String)
    case empty
    case rows

    init(isEmpty: Bool, isLoading: Bool, error: String?, wasAsked: Bool) {
        if !isEmpty {
            self = .rows
        } else if isLoading {
            self = .loading
        } else if let error {
            self = .failed(error)
        } else {
            self = wasAsked ? .empty : .loading
        }
    }

    init(_ source: some PagedSource, isEmpty: Bool) {
        self.init(isEmpty: isEmpty, isLoading: source.isLoading, error: source.firstPageError,
                  wasAsked: source.hasLoaded || source.firstPageError != nil)
    }

    init<Item>(_ list: FreshList<Item>, isEmpty: Bool) {
        self.init(isEmpty: isEmpty, isLoading: list.isLoading, error: list.error,
                  wasAsked: list.hasLoaded || list.error != nil)
    }
}

extension View {
    /// The failure and the empty state over a list that has no rows; a skeleton, if any, is the list's own.
    func listStatus(_ phase: ListPhase, failure title: String = "Couldn't load",
                    retry: @escaping () -> Void,
                    @ViewBuilder empty: () -> some View = { EmptyView() }) -> some View {
        let empty = empty()
        return overlay {
            switch phase {
            case .failed(let message): LoadFailure(title: title, message: message, retry: retry)
            case .empty: empty
            case .loading, .rows: EmptyView()
            }
        }
    }
}
