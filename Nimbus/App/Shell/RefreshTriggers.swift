import AppKit
import Network
import os
import SwiftUI

@Observable
final class PageReloads {
    private var counts: [AnyHashable: Int] = [:]

    func count(for page: AnyHashable) -> Int { counts[page] ?? 0 }

    func reload(_ page: AnyHashable) { counts[page, default: 0] += 1 }
}

extension View {
    // A new count is a new identity, and a new identity starts the page over — its `.task`s included.
    func reloads(_ page: AnyHashable, with reloads: PageReloads) -> some View {
        ReloadablePage(page: page, reloads: reloads, content: self)
    }
}

private struct ReloadablePage<Content: View>: View {
    let page: AnyHashable
    let reloads: PageReloads
    let content: Content

    var body: some View {
        content.id(reloads.count(for: page))
    }
}

@MainActor
final class RefreshTriggers {
    private let model: AppModel
    private var observers: [any NSObjectProtocol] = []
    private var network: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStale(because: "app active") }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStale(because: "wake") }
        })
        // Straight after a wake the connection is usually still coming up, and that first try fails.
        network = Task { [weak self] in
            var wasOnline = true
            for await path in NWPathMonitor() {
                let isOnline = path.status == .satisfied
                if isOnline, !wasOnline { self?.refreshStale(because: "network back") }
                wasOnline = isOnline
            }
        }
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        network?.cancel()
    }

    private func refreshStale(because reason: String) {
        refreshLog.info("trigger: \(reason, privacy: .public)")
        model.library.refreshStale()
    }
}

extension ShellState {
    func refreshShownPage() {
        let section = shown as? LibrarySection
        let name = section?.rawValue ?? "\(type(of: shown.base))"
        refreshLog.info("trigger: ⌘R on \(name, privacy: .public)")
        switch section {
        case .search:
            model.library.search.retry()
        case .profile:
            model.library.reloadMe()
            // Kept, the model would come straight back to the new identity with nothing left to load.
            model.pages.drop { $0.isMe }
            reloads.reload(shown)
        case let section?:
            let library = model.library, player = model.player
            Task {
                if await !library.refresh(section.lists) {
                    player.report("Couldn't refresh — check your connection")
                }
            }
        case nil:
            if let key = PageModelKey(page: shown) { model.pages.drop { $0 == key } }
            reloads.reload(shown)
        }
    }
}

private extension LibrarySection {
    var lists: [LibraryList] {
        switch self {
        case .home: [.selections, .history, .trending]
        case .feed: [.stream]
        case .likes: [.likes]
        case .history: [.history]
        case .playlists, .albums, .stations: [.playlists]
        case .following: [.following]
        case .search, .profile: []
        }
    }
}
