import SwiftUI

/// First screen of the app. Signing in happens in SoundCloud's own web page — there is no other way
/// to get a token — but dropping someone straight into a browser view makes the app look like a
/// wrapper, so the web view is something you opt into from here.
struct WelcomeView: View {
    let model: AppModel

    @State private var showLogin = false

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                Spacer()

                mark
                    .padding(.bottom, 26)

                Text("Nimbus")
                    .font(.system(size: 44, weight: .bold))

                Text("A native SoundCloud player for macOS")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                features
                    .padding(.top, 34)

                Button { showLogin = true } label: {
                    Text("Continue with SoundCloud")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 240, height: 20)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 36)

                Text("Nimbus signs you in on soundcloud.com — your password never reaches the app.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 12)

                Spacer()

                Link("Powered by SoundCloud", destination: URL(string: "https://soundcloud.com")!)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 18)
            }
            .multilineTextAlignment(.center)
        }
        .sheet(isPresented: $showLogin) {
            LoginSheet(model: model) { showLogin = false }
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [Color.scOrange.opacity(0.28), Color.scOrange.opacity(0.04), .clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }

    private var mark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [.scOrange, .scOrange.opacity(0.65)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 104, height: 104)
                .shadow(color: .scOrange.opacity(0.35), radius: 22, y: 8)

            Image(systemName: "waveform")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var features: some View {
        HStack(alignment: .top, spacing: 30) {
            feature("list.bullet", "Real queue", "Reorder what plays next")
            feature("shuffle", "True shuffle", "Across the whole library")
            feature("playpause", "System controls", "Media keys and Now Playing")
        }
        .frame(maxWidth: 520)
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(.tint)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(width: 140)
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
        .frame(width: 520, height: 640)
    }
}
