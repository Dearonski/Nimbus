import Foundation

extension ProcessInfo {
    /// A preview runs the real app code in a throwaway process that must not touch the user's state.
    nonisolated static let isRunningForPreviews = processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
}
