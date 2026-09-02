// Renders the app icon and the menu-bar template straight from the app's own shapes, so the PNGs in
// Assets.xcassets can never drift from NimbusMark.swift. Run from the repo root:
//
//   xcrun swiftc -swift-version 6 -O Nimbus/Components/NimbusMark.swift Nimbus/App/Theme.swift \
//     tools/render-icons/main.swift -o /tmp/rendericon && /tmp/rendericon /tmp/icons
//
// then copy /tmp/icons into the catalogs (see tools/render-icons/install.sh).

import SwiftUI
import AppKit

@MainActor
func writePNG<V: View>(_ view: V, side: CGFloat, to path: String) {
    let renderer = ImageRenderer(content: view.frame(width: side, height: side))
    renderer.scale = 1
    renderer.isOpaque = false
    guard let cg = renderer.cgImage else { fatalError("render failed for \(path)") }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: side, height: side)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png failed") }
    try! data.write(to: URL(fileURLWithPath: path))
}

/// Classic macOS icon grid: the plate is 824/1024 of the canvas with a 185.4/1024 corner radius.
struct AppIconArtwork: View {
    var side: CGFloat
    var body: some View {
        MarkTile(size: side * 0.8046, cornerRadius: side * 0.1811)
            .frame(width: side, height: side)
    }
}

struct MenuBarArtwork: View {
    var side: CGFloat
    var body: some View {
        NimbusMark(letter: .black, knob: .black)
            .frame(width: side * 0.92, height: side * 0.92)
            .frame(width: side, height: side)
    }
}

let out = CommandLine.arguments[1]
MainActor.assumeIsolated {
    for side in [16, 32, 64, 128, 256, 512, 1024] as [CGFloat] {
        writePNG(AppIconArtwork(side: side), side: side, to: "\(out)/icon_\(Int(side)).png")
    }
    for side in [16, 32, 48] as [CGFloat] {
        writePNG(MenuBarArtwork(side: side), side: side, to: "\(out)/menubar_\(Int(side)).png")
    }
    writePNG(MarkTile(size: 1024), side: 1024, to: "\(out)/fullbleed_1024.png")
}
