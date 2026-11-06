import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class ActivityStore {
    let list = FreshList<SCActivity>("activity", ttl: .seconds(5 * 60))
    var items: [SCActivity] { list.items }

    // There is no unread count in the API, so "new" is anything after the newest event the page has shown.
    private(set) var seenUntil: Date? = UserDefaults.standard.object(forKey: Keys.seen) as? Date {
        didSet { UserDefaults.standard.set(seenUntil, forKey: Keys.seen) }
    }
    private var notifiedUntil: Date? = UserDefaults.standard.object(forKey: Keys.notified) as? Date {
        didSet { UserDefaults.standard.set(notifiedUntil, forKey: Keys.notified) }
    }

    var unseenCount: Int {
        guard let seenUntil else { return 0 }
        return items.count { ($0.date ?? .distantPast) > seenUntil }
    }

    private var newest: Date? { items.compactMap(\.date).max() }

    init(api: SoundCloudAPI) {
        list.fetch = { try await api.activities() }
    }

    func loadIfNeeded(force: Bool = false) {
        Task { await update(force: force) }
    }

    @discardableResult
    func update(force: Bool) async -> Bool {
        let reached = await list.update(force: force)
        guard let newest else { return reached }
        // A first load counts nothing as new: a year of old follows is not news.
        if seenUntil == nil { seenUntil = newest }
        if let notifiedUntil, Preference.notifiesActivity {
            notify(items.filter { ($0.date ?? .distantPast) > notifiedUntil })
        }
        if notifiedUntil.map({ newest > $0 }) ?? true { notifiedUntil = newest }
        return reached
    }

    // The site polls every 2 to 32 minutes; this runs as long as the signed-in window does.
    func keepFresh() async {
        while !Task.isCancelled {
            await update(force: false)
            try? await Task.sleep(for: .seconds(5 * 60))
        }
    }

    func markSeen() {
        guard let newest, seenUntil.map({ newest > $0 }) ?? true else { return }
        seenUntil = newest
    }

    func reset() {
        list.reset()
        seenUntil = nil
        notifiedUntil = nil
    }

    private func notify(_ fresh: [SCActivity]) {
        let center = UNUserNotificationCenter.current()
        for activity in fresh.prefix(3) {
            let content = UNMutableNotificationContent()
            content.title = activity.user.username
            content.body = [activity.action, activity.subjectTitle.map { "“\($0)”" }].compactMap(\.self)
                .joined(separator: " ") + (activity.comment.map { ": \($0.body)" } ?? "")
            content.threadIdentifier = "activity"
            center.add(UNNotificationRequest(identifier: activity.id, content: content, trigger: nil))
        }
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private enum Keys {
        static let seen = "activitySeenUntil"
        static let notified = "activityNotifiedUntil"
    }
}
