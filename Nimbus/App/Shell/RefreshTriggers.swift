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

    func refreshTriggers(model: AppModel, shown: AnyHashable, reloads: PageReloads) -> some View {
        modifier(RefreshTriggers(model: model, shown: shown, reloads: reloads))
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

private struct RefreshTriggers: ViewModifier {
    let model: AppModel
    let shown: AnyHashable
    let reloads: PageReloads

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshStale(because: "app active")
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                refreshStale(because: "wake")
            }
            // Straight after a wake the connection is usually still coming up, and that first try fails.
            .task {
                var wasOnline = true
                for await path in NWPathMonitor() {
                    let isOnline = path.status == .satisfied
                    if isOnline, !wasOnline { refreshStale(because: "network back") }
                    wasOnline = isOnline
                }
            }
            .onChange(of: model.refreshRequest) { refreshShownPage() }
    }

    private func refreshStale(because reason: String) {
        refreshLog.info("trigger: \(reason, privacy: .public)")
        model.library.refreshStale()
    }

    private func refreshShownPage() {
        let section = shown as? LibrarySection
        let name = section?.rawValue ?? "\(type(of: shown.base))"
        refreshLog.info("trigger: ⌘R on \(name, privacy: .public)")
        switch section {
        case .search:
            model.library.retrySearch()
        case .profile:
            model.library.reloadMe()
            reloads.reload(shown)
        case let section?:
            let library = model.library, player = model.player
            Task {
                if await !library.refresh(section.lists) {
                    player.report("Couldn't refresh — check your connection")
                }
            }
        case nil:
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
