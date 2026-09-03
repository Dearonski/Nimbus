import SwiftUI

/// First screen of the app. Signing in happens in SoundCloud's own web page — there is no other way
/// to get a token — but dropping someone straight into a browser view makes the app look like a
/// wrapper, so the web view is something you opt into from here.
///
/// Shaped like a system welcome window rather than a landing page: the plate the icon sits on is the
/// only colour, so nothing competes with it, and the column holds its width whatever the window does.
struct WelcomeView: View {
    let model: AppModel

    @State private var showLogin = false

    private static let features: [(symbol: String, title: String, detail: String)] = [
        ("list.bullet", "A real queue", "See what plays next and drag it into order"),
        ("shuffle", "Shuffle that means it", "Across a whole collection, not the page you loaded"),
        ("playpause", "At home on the Mac", "Media keys, Now Playing and the system controls"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)

            MarkTile(size: 96, cornerRadius: 22)

            Text("Nimbus")
                .font(.system(size: 28, weight: .semibold))
                .padding(.top, 18)

            Text("A native SoundCloud player for macOS")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(Self.features, id: \.title) { feature($0) }
            }
            .padding(.top, 32)

            Button { showLogin = true } label: {
                Text("Continue with SoundCloud").frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 34)

            Text("You sign in on soundcloud.com — Nimbus never sees your password.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 12)

            Spacer(minLength: 32)

            HStack(spacing: 6) {
                Text(version)
                Text("·")
                Link("Powered by SoundCloud", destination: URL(string: "https://soundcloud.com")!)
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showLogin) {
            LoginSheet(model: model) { showLogin = false }
        }
    }

    private func feature(_ item: (symbol: String, title: String, detail: String)) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: item.symbol)
                .font(.system(size: 14))
                .foregroundStyle(.tint)
                .frame(width: 20, height: 17)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13, weight: .semibold))
                Text(item.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }
}

/// The web login, framed as a sheet so it reads as a step of signing in rather than as the app.
private struct LoginSheet: View {
    let model: AppModel
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to SoundCloud").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            LoginWebView { _ in
                model.didAuthenticate()
                onCancel()
            }
        }
        // SoundCloud only centres the /signin card past its desktop breakpoint (~1000pt); narrower
        // than that it drifts right of centre or collapses to a scroll-past-hero mobile layout.
        .frame(width: 1040, height: 760)
    }
}
