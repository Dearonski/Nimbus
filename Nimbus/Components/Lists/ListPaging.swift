import CoreGraphics

/// What a list shows under its last row, and what it asks for when the rows run out.
struct ListPaging {
    var isLoading = false
    var error: String?
    var loadMore: (() async -> Void)?
    /// False until a first page has come: an empty list is already at its end, and paging it then
    /// started the first page behind its owner's back.
    var canPage = false
    var padding: CGFloat = 12

    init(_ source: some PagedSource, padding: CGFloat = 12) {
        isLoading = source.isLoading
        error = source.nextPageError
        self.padding = padding
        canPage = source.hasLoaded
        loadMore = { await source.loadMore() }
    }

    /// A load with nothing to page, like a set resolving its tracks.
    init(isLoading: Bool, padding: CGFloat = 12) {
        self.isLoading = isLoading
        self.padding = padding
    }

    var height: CGFloat {
        isLoading || (error != nil && loadMore != nil) ? FeedFooter.height(padding: padding) : 0
    }

    var footer: FeedFooter {
        FeedFooter(isLoading: isLoading, padding: padding, error: error, retry: loadMore)
    }
}
