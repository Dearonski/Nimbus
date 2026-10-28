import AppKit
import Nuke
import NukeUI
import SwiftUI

/// A cover or an avatar opened full size, and the place on the page it grew out of.
struct ArtworkViewing: Equatable {
    /// The size already on screen — cached, so the lightbox has a picture from its first frame.
    let preview: URL
    /// The upload itself, swapped in over the preview once it arrives.
    let original: URL?
    let title: String
    /// An avatar leaves a circle and opens square: the upload has corners the page crops away.
    let isCircle: Bool
    /// Which view on the page it came from, so exactly that one hides while the copy flies.
    let sourceID: UUID
    /// In screen coordinates, read off AppKit at the moment of the click.
    let screenRect: CGRect
}

/// Shared by the whole window: one lightbox, opened from any page and closed from the keyboard
/// monitor in the shell as well as by a click.
///
/// It is drawn in a borderless panel of its own, laid over the window as a child. An overlay inside
/// the window can't reach the toolbar — AppKit draws the title and the back button above all
/// SwiftUI content, so they stayed lit and live, and Back navigated away from under an open
/// picture. Hiding the toolbar instead re-lays the window, moving the sidebar and the window
/// buttons. A child panel covers all of it and changes nothing underneath.
@MainActor
@Observable
final class ArtworkViewer {
    private(set) var viewing: ArtworkViewing?
    private(set) var isExpanded = false
    /// The page's view, in the panel's own top-down space.
    private(set) var sourceInPanel: CGRect = .zero

    /// Made once and kept: a fresh hosting view has no size on its first pass, and a picture laid
    /// out against nothing is exactly what jumped to the middle before it could grow.
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var host: NSView?
    @ObservationIgnored private var resizeObserver: (any NSObjectProtocol)?

    func open(_ item: ArtworkViewing) {
        guard viewing == nil, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let panel = self.panel ?? makePanel()
        panel.setFrame(window.frame, display: false)
        window.addChildWindow(panel, ordered: .above)

        // Plain window arithmetic: the panel has the window's frame, and screen space runs bottom-up
        // where SwiftUI's runs top-down. Measuring through SwiftUI's coordinate spaces instead put
        // the copy a titlebar's height below the avatar it was meant to grow out of.
        sourceInPanel = CGRect(x: item.screenRect.minX - window.frame.minX,
                               y: window.frame.maxY - item.screenRect.maxY,
                               width: item.screenRect.width, height: item.screenRect.height)
        isExpanded = false
        viewing = item

        // The starting frame has to reach the screen before the spring runs. Changed in the same
        // pass as the insertion — from onAppear — SwiftUI never draws the source-sized copy, so
        // position snapped to the centre and only the size animated.
        host?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        Task {
            try? await Task.sleep(for: .milliseconds(16))
            guard viewing?.sourceID == item.sourceID, !isExpanded else { return }
            withAnimation(.spring(duration: 0.38, bounce: 0.1)) { isExpanded = true }
        }

        // A resize — entering full screen, say — would leave the picture's way back pointing at a
        // spot the page no longer occupies, so the lightbox just goes.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tearDown() }
        }
    }

    func dismiss() {
        guard viewing != nil, isExpanded else { return }
        withAnimation(.spring(duration: 0.3, bounce: 0)) {
            isExpanded = false
        } completion: {
            self.tearDown()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        // Never key: the shell's keyboard monitor keeps receiving Esc and Space from the window.
        let host = NSHostingView(rootView: ArtworkLightbox().environment(self))
        // Left to its defaults the hosting view sizes the window to its content; the panel has to
        // keep exactly the window's frame.
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        self.host = host
        return panel
    }

    private func tearDown() {
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        viewing = nil
        isExpanded = false
    }
}

extension View {
    /// Opens this cover or avatar full size in the window's lightbox. Does nothing without a real
    /// image — a gradient placeholder has nothing more to show.
    func opensArtwork(_ url: String?, preview size: ArtworkSize, title: String,
                      circle: Bool = false) -> some View {
        modifier(OpensArtwork(raw: url.liveArtwork, size: size, title: title, circle: circle))
    }
}

private struct OpensArtwork: ViewModifier {
    let raw: String?
    let size: ArtworkSize
    let title: String
    let circle: Bool

    @Environment(ArtworkViewer.self) private var viewer: ArtworkViewer?
    @State private var id = UUID()
    @State private var probe = ScreenFrameProbe()

    private var preview: URL? { raw.scArtwork(size) }

    /// The copy in the lightbox stands in for this view while it flies, so the page underneath
    /// doesn't show the same picture twice.
    private var isStandIn: Bool { viewer?.viewing?.sourceID == id }

    func body(content: Content) -> some View {
        if let preview, let viewer {
            content
                .background(ScreenFrameReader(probe: probe))
                .opacity(isStandIn ? 0 : 1)
                .contentShape(circle ? AnyShape(Circle()) : AnyShape(Rectangle()))
                .onTapGesture {
                    guard let rect = probe.screenRect else { return }
                    viewer.open(ArtworkViewing(preview: preview, original: raw.scArtwork(.original),
                                               title: title, isCircle: circle, sourceID: id,
                                               screenRect: rect))
                }
                .pointerStyle(.zoomIn)
                .help("View full size")
        } else {
            content
        }
    }
}

/// Holds the AppKit view sitting behind a cover, to ask it where on screen it is.
@MainActor
private final class ScreenFrameProbe {
    weak var view: NSView?

    var screenRect: CGRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct ScreenFrameReader: NSViewRepresentable {
    let probe: ScreenFrameProbe

    func makeNSView(context: Context) -> NSView {
        let view = TransparentView()
        probe.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        probe.view = nsView
    }

    /// Behind the cover and never in the way of its click.
    private final class TransparentView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The window dims and the picture grows out of the page into a square fitted to the window. No
/// zoom or panning: uploads are rarely bigger than that — the ones measured were 500 to 1170
/// pixels — so the whole picture already shows.
struct ArtworkLightbox: View {
    @Environment(ArtworkViewer.self) private var viewer
    @Environment(\.openURL) private var openURL

    /// Keyed by the original's URL rather than reset per opening: a second look at the same cover
    /// finishes from cache before any reset could run, and would lose its size to it.
    @State private var sizes: [URL: CGSize] = [:]
    @State private var failedSave: URL?

    private static let margin: CGFloat = 56
    private static let maxSide: CGFloat = 720

    var body: some View {
        if let item = viewer.viewing {
            GeometryReader { proxy in
                let source = viewer.sourceInPanel
                let target = targetFrame(in: proxy.size)
                let frame = viewer.isExpanded ? target : source
                let radius = viewer.isExpanded || !item.isCircle ? 10 : frame.width / 2

                ZStack(alignment: .topLeading) {
                    Color.black
                        .opacity(viewer.isExpanded ? 0.84 : 0)
                        .contentShape(Rectangle())
                        .onTapGesture { viewer.dismiss() }

                    picture(item)
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                        .shadow(color: .black.opacity(viewer.isExpanded ? 0.5 : 0), radius: 30, y: 12)
                        .offset(x: frame.minX, y: frame.minY)
                        .onTapGesture { viewer.dismiss() }
                        .contextMenu { menu(item) }

                    if failedSave == (item.original ?? item.preview) {
                        saveFailureToast
                            .frame(width: max(target.width, 320))
                            .offset(x: target.midX - max(target.width, 320) / 2, y: target.maxY + 14)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    /// Known before the first frame, so the picture grows once and stays put: SoundCloud covers and
    /// avatars are square, and waiting on the original's pixel size to cap the frame changed the
    /// target halfway through the spring. The cap keeps a 500px upload from being blown up to fill
    /// a large window; the real resolution is in the caption either way.
    private func targetFrame(in space: CGSize) -> CGRect {
        let side = max(min(space.width - Self.margin * 2,
                           space.height - Self.margin * 2,
                           Self.maxSide), 1)
        return CGRect(x: (space.width - side) / 2,
                      y: (space.height - side) / 2,
                      width: side, height: side)
    }

    private func picture(_ item: ArtworkViewing) -> some View {
        ZStack {
            LazyImage(url: item.preview) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            if let original = item.original {
                LazyImage(url: original) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .onCompletion { result in
                    guard case .success(let response) = result, sizes[original] == nil else { return }
                    let rep = response.image.representations.first
                    let size = rep.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
                        ?? response.image.size
                    sizes[original] = size
                }
            }
        }
    }

    /// Only failure gets a word on screen. The title is what the page already showed, and the
    /// pixel size belongs in the menu, where saving is decided.
    private var saveFailureToast: some View {
        Text("Couldn't save")
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.75))
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func menu(_ item: ArtworkViewing) -> some View {
        let url = item.original ?? item.preview
        let pixels = item.original.flatMap { sizes[$0] }
        let measured = pixels.map { " \(Int($0.width)) × \(Int($0.height))" } ?? ""
        Button("Copy Image", systemImage: "doc.on.doc") { copy(url, fallback: item.preview) }
        Button("Save Image\(measured)…", systemImage: "square.and.arrow.down") {
            save(url, title: item.title)
        }
        Divider()
        Button("Open in Browser", systemImage: "safari") { openURL(url) }
    }

    private func copy(_ url: URL, fallback: URL) {
        let cache = ImagePipeline.shared.cache
        guard let image = cache[ImageRequest(url: url)]?.image ?? cache[ImageRequest(url: fallback)]?.image
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private func save(_ url: URL, title: String) {
        let panel = NSSavePanel()
        // Named after what is in it rather than the CDN's hash, and in the format the upload came as.
        let safe = title.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(safe).\(url.pathExtension.isEmpty ? "jpg" : url.pathExtension)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try data.write(to: destination)
                failedSave = nil
            } catch {
                failedSave = url
            }
        }
    }
}
