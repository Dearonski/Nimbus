# Nimbus

A native SoundCloud client for macOS — built in SwiftUI, shaped like a Mac app rather than a web
page in a window.

<!-- screenshots go here -->

## What it does

- **Plays without the gap.** Two decks with the next track warmed up ahead of time, so a change of
  track lands in tens of milliseconds instead of a second and a half.
- **A queue you can rearrange**, with drag and drop, and a player that stays out of the way.
- **The waveform, with its comments** — faces sit on the second they were written at, the way the
  site draws them.
- **Now Playing and the media keys**, because it is a Mac app.
- **Comments, likes, reposts and follows** — reading and writing, not a read-only viewer.

## Requirements

**macOS 26.0 or later, on Apple Silicon.** The interface is built on Liquid Glass, which arrived in
macOS 26; there is no fallback for earlier versions, and no Intel build.

## Installing

No packaged release yet — build it yourself:

```
git clone https://github.com/Dearonski/Nimbus.git
cd Nimbus
open Nimbus.xcodeproj
```

Then run the `Nimbus` scheme. Signing is automatic; you need an Apple developer account (a free one
is enough) selected in the target's Signing & Capabilities.

Sign in happens in a web view, the same as on soundcloud.com.

## Status

Pre-release, and honest about it: the app is in daily use by its author, packaging and a signed,
notarised build are the next step. Bug reports are welcome — `Help → Report an Issue…` inside the
app fills in the version, the system and a slice of the log for you.

## Not affiliated with SoundCloud

Nimbus is an unofficial client, not connected with SoundCloud in any way. It talks to the same
internal API the website uses, with your own session, and it is meant for personal use. SoundCloud's
Terms of Service apply to you as a listener exactly as they do in the browser.

Powered by SoundCloud.

## Thanks

- [nuage-macos](https://github.com/lbrndnr/nuage-macos) — a SwiftUI SoundCloud client whose reading
  of the internal API saved a great deal of guessing.
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) — where the approach to SoundCloud's rotating
  `client_id` comes from.

## License

MIT — see [LICENSE](LICENSE).
