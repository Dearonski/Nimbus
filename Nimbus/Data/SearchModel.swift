import Foundation
import Observation

/// Debounced search of the whole catalogue; local FTS5 results from the cache land at once, undebounced.
@MainActor
@Observable
final class SearchModel {
    private(set) var results: [SCSearchItem] = []
    private(set) var localResults: [SCTrack] = []
    private(set) var isSearching = false
    private(set) var error: String?

    private let api: SoundCloudAPI
    private let database: AppDatabase?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var query = ""

    init(api: SoundCloudAPI, database: AppDatabase?) {
        self.api = api
        self.database = database
    }

    func run(_ text: String) {
        task?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        query = trimmed
        guard !trimmed.isEmpty else {
            results = []
            error = nil
            localResults = []
            isSearching = false
            return
        }
        isSearching = true
        if let database {
            Task.detached {
                let local = database.search(trimmed, limit: 50)
                await MainActor.run {
                    guard self.query == trimmed else { return }
                    self.localResults = local
                }
            }
        }
        task = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                let page = try await api.search(trimmed)
                guard !Task.isCancelled else { return }
                results = page.collection
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                self.error = error.surfaced()
            }
            isSearching = false
        }
    }

    func retry() {
        run(query)
    }

    func reset() {
        task?.cancel()
        task = nil
        query = ""
        isSearching = false
        results = []
        error = nil
        localResults = []
    }
}
