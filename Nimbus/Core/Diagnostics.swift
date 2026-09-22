import AppKit
import OSLog

/// What a bug report needs and where it comes from.
///
/// No crash reporter and no telemetry: the app is sandboxed, so the system's own `.ips` reports sit
/// where it cannot read them, and a Swift `fatalError` is not something a signal handler catches
/// reliably anyway. What is left is worth more than either — knowing the last run ended badly, and
/// handing the person a report they only have to describe in words.
@MainActor
enum Diagnostics {
    private static let cleanExitKey = "diagnostics.cleanExit"
    private static let subsystem = "io.github.dearonski.Nimbus"
    private static let repository = "https://github.com/Dearonski/Nimbus"

    /// Whether the previous launch went away without saying goodbye — a crash, a force quit, or a
    /// power cut. The app cannot tell those apart, and says so rather than claiming a crash.
    private(set) static var previousRunEndedBadly = false

    /// Called before anything else can crash.
    static func begin() {
        // A debug run ends in an Xcode stop or a crash on purpose; neither is worth a notice.
        #if !DEBUG
        previousRunEndedBadly = !(UserDefaults.standard.object(forKey: cleanExitKey) as? Bool ?? true)
        UserDefaults.standard.set(false, forKey: cleanExitKey)
        #endif
    }

    static func end() {
        #if !DEBUG
        UserDefaults.standard.set(true, forKey: cleanExitKey)
        #endif
    }

    /// The app's own log lines, which `OSLogStore` hands back without any entitlement as long as the
    /// scope stays this process. Nothing from the run that crashed survives here — that is what
    /// MetricKit would be for — so a report written after a restart carries the current run.
    static func recentLog(minutes: Double = 10, limit: Int = 120) -> String {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return "unavailable" }
        let start = store.position(date: Date().addingTimeInterval(-minutes * 60))
        guard let entries = try? store.getEntries(at: start) else { return "unavailable" }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let lines = entries
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == subsystem }
            .suffix(limit)
            .map { "\(formatter.string(from: $0.date)) [\($0.category)] \($0.composedMessage)" }
        return lines.isEmpty ? "(nothing logged)" : lines.joined(separator: "\n")
    }

    static var environment: String {
        let bundle = Bundle.main.infoDictionary
        let version = bundle?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return """
        Nimbus \(version) (\(build))
        \(os)
        Previous run: \(previousRunEndedBadly ? "ended unexpectedly" : "exited cleanly")
        """
    }

    static func report() -> String {
        """
        ### What happened



        ### Steps



        ### Environment

        ```
        \(environment)
        ```

        ### Log

        ```
        \(recentLog())
        ```
        """
    }

    /// Opens a prefilled issue. GitHub takes the body in the query string, but a long log makes a
    /// URL no browser will follow — past that the report goes to the clipboard and the blank issue
    /// form opens instead, with a line saying where the text went.
    static func reportIssue() {
        let body = report()
        var components = URLComponents(string: "\(repository)/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "title", value: previousRunEndedBadly ? "Crash: " : ""),
            URLQueryItem(name: "body", value: body),
        ]
        if let url = components.url, url.absoluteString.count < 7_000 {
            NSWorkspace.shared.open(url)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
        if let plain = URL(string: "\(repository)/issues/new") {
            NSWorkspace.shared.open(plain)
        }
    }
}
