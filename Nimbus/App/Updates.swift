import Sparkle
import SwiftUI

@Observable
final class Updates {
    private(set) var canCheck = false
    // A debug build would be offered the published release and replace itself with it.
    #if DEBUG
    private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    #else
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif
    private var observation: NSKeyValueObservation?

    init() {
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
        }
    }

    func check() {
        controller.checkForUpdates(nil)
    }
}
