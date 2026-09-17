import Foundation
import OSLog
import Testing
@testable import Nimbus

/// The report is only worth having if the log actually comes back. `OSLogStore` needs no
/// entitlement for the current process, but a sandbox has surprised us before, so this holds it to
/// account rather than assuming.
@Suite(.serialized)
struct DiagnosticsTests {
    @MainActor
    @Test func collectsItsOwnLog() async throws {
        let marker = "diagnostics probe \(UUID().uuidString)"
        Logger(subsystem: "io.github.dearonski.Nimbus", category: "test")
            .error("\(marker, privacy: .public)")

        // The store is written to asynchronously; a moment is enough for the entry to land.
        try await Task.sleep(for: .milliseconds(600))

        let log = Diagnostics.recentLog(minutes: 1)
        #expect(log.contains(marker), "the app cannot read back its own log: \(log.prefix(200))")
    }

    @MainActor
    @Test func reportCarriesVersionAndLog() {
        let report = Diagnostics.report()
        #expect(report.contains("Nimbus "))
        #expect(report.contains("Previous run:"))
        #expect(report.contains("### Log"))
    }
}
