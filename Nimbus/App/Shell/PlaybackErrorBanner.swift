import SwiftUI

/// Surfaces a failed track (geo/Go+ block, dropped connection) instead of leaving the queue looking
/// like it silently stalled — the engine keeps skipping, this just says why.
struct PlaybackErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).lineLimit(2)
            Spacer(minLength: 8)
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassPanel(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Shown once after a launch that never said goodbye. It does not claim a crash — a force quit and
/// a dead battery look the same from here — and its only job is to catch the report while the
/// person still remembers what they were doing.
struct CrashNoticeBanner: View {
    let onReport: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.bubble").foregroundStyle(.orange)
            Text("Nimbus closed unexpectedly last time.")
                .font(.system(size: 12))
            Button("Report", action: onReport)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            Spacer(minLength: 8)
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassPanel(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
