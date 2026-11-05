import Sparkle
import SwiftUI

@Observable
final class Updates {
    private(set) var canCheck = false
    var checksAutomatically: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = checksAutomatically }
    }
    var downloadsAutomatically: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = downloadsAutomatically }
    }
    #if DEBUG
    let isActive = false
    #else
    let isActive = true
    #endif
    // A debug build would be offered the published release and replace itself with it.
    #if DEBUG
    private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    #else
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif
    private var observation: NSKeyValueObservation?

    init() {
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        downloadsAutomatically = controller.updater.automaticallyDownloadsUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
        }
    }

    func check() {
        controller.checkForUpdates(nil)
    }
}
