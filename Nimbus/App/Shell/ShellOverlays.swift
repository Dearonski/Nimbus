import SwiftUI

/// What floats over the detail column: the player pill along the bottom, and a playback error or
/// the note about the last run's crash along the top.
struct ShellOverlays: ViewModifier {
    let model: AppModel
    let column: DetailColumnFrame
    let fullPlayer: FullPlayerPresenter
    @Binding var showQueue: Bool
    @Binding var showsCrashNotice: Bool
    let open: (AnyHashable) -> Void
    let expand: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomLeading) {
                OverDetailColumn(frame: column) {
                    PlayerPill(
                        player: model.player,
                        onOpenTrack: { open($0) },
                        onOpenArtist: { open($0) },
                        onExpand: expand,
                        onArtworkView: { fullPlayer.pillArtwork = $0 },
                        hidesArtwork: fullPlayer.isOpen,
                        isQueueVisible: $showQueue)
                }
            }
            .overlay(alignment: .topLeading) {
                if let error = model.player.lastError {
                    OverDetailColumn(frame: column) {
                        PlaybackErrorBanner(message: error) { model.player.dismissError() }
                    }
                } else if showsCrashNotice {
                    OverDetailColumn(frame: column) {
                        CrashNoticeBanner {
                            Diagnostics.reportIssue()
                            showsCrashNotice = false
                        } onDismiss: {
                            showsCrashNotice = false
                        }
                    }
                }
            }
            .animation(.snappy, value: showsCrashNotice)
            .animation(.snappy, value: model.player.lastError)
    }
}

/// Frame of the detail column inside the split view. The pill has to be an overlay on the whole
/// split view — the only placement that survives a NavigationStack push on macOS — so it needs
/// both the width and the origin to sit over the detail alone, and it tracks the column as the
/// sidebar or the queue inspector resize it.
// A reference the shell never reads: the column resizes every frame while the inspector slides in.
@Observable
final class DetailColumnFrame {
    var span = ColumnSpan()
}

nonisolated struct ColumnSpan: Equatable {
    var minX: CGFloat = 0
    var width: CGFloat = 0
}

private struct OverDetailColumn<Content: View>: View {
    let frame: DetailColumnFrame
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: frame.span.width)
            .offset(x: frame.span.minX)
    }
}
