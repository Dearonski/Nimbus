import AppKit
import SwiftUI

// Bars rasterised once and windowed by runs Core Animation moves: a SwiftUI tick here relaid the whole window out.
struct WaveformView: NSViewRepresentable {
    let waveform: Waveform?
    var playhead = Playhead.still(0)
    var hoverProgress: Double = 0
    var remainingColor: Color = .primary
    var highlight: Double = 0

    nonisolated static let barWidth: CGFloat = 3
    nonisolated static let barSpacing: CGFloat = 1
    nonisolated static let topRatio: CGFloat = 0.68
    nonisolated static let centreGap: CGFloat = 2

    nonisolated static func barsBottom(in height: CGFloat) -> CGFloat {
        (height - centreGap) * topRatio
    }

    nonisolated static func barsSpan(in width: CGFloat) -> CGFloat {
        CGFloat(max(Int(width / (barWidth + barSpacing)), 1)) * (barWidth + barSpacing)
    }

    func makeNSView(context: Context) -> WaveformLayerView { WaveformLayerView() }

    func updateNSView(_ view: WaveformLayerView, context: Context) {
        let environment = context.environment
        let remaining = remainingColor.resolve(in: environment).cgColor
        let accent = Color.scOrange.resolve(in: environment).cgColor
        func tone(_ color: CGColor, _ alpha: CGFloat) -> CGColor { color.copy(alpha: color.alpha * alpha) ?? color }
        view.show(waveform,
                  palette: .init(remaining: (tone(remaining, 0.22), tone(remaining, 0.1)),
                                 preview: tone(accent, 0.45),
                                 played: (accent, tone(accent, 0.35)),
                                 lit: (tone(remaining, 0.42), tone(remaining, 0.16))),
                  scale: environment.displayScale)
        view.run(.init(playhead: playhead, hover: min(max(hoverProgress, 0), 1)))
        view.light(highlight, animated: context.transaction.animation != nil)
    }

    // Always handed a frame; left to itself the host would measure the layers through Auto Layout.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WaveformLayerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

final class WaveformLayerView: NSView {
    struct Palette: Equatable {
        var remaining: (top: CGColor, bottom: CGColor)
        var preview: CGColor
        var played: (top: CGColor, bottom: CGColor)
        var lit: (top: CGColor, bottom: CGColor)

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.remaining == rhs.remaining && lhs.preview == rhs.preview
                && lhs.played == rhs.played && lhs.lit == rhs.lit
        }
    }

    struct Motion: Equatable {
        let playhead: Playhead
        let hover: Double
    }

    // Linear in the playhead between the moments it passes the pointer, so a keyframe animation carries it exactly.
    private enum Edge {
        case start, end, played, solid, dim

        func at(_ played: Double, hover: Double) -> Double {
            switch self {
            case .start: 0
            case .end: 1
            case .played: played
            // Bars a click would keep stay solid, bars it would give up or gain go dim.
            case .solid: hover > 0 ? min(hover, played) : played
            case .dim: hover > 0 ? max(hover, played) : played
            }
        }
    }

    private final class Tone {
        let container = CALayer()
        let bars = CALayer()
        let top = CALayer()
        let bottom = CALayer()
        let topRun = CALayer()
        let bottomRun = CALayer()
        let topEdges: (Edge, Edge)
        let bottomEdges: (Edge, Edge)?

        init(top topEdges: (Edge, Edge), bottom bottomEdges: (Edge, Edge)?) {
            self.topEdges = topEdges
            self.bottomEdges = bottomEdges
            container.mask = bars
            for (band, run) in [(top, topRun), (bottom, bottomRun)] {
                run.anchorPoint = .zero
                run.backgroundColor = .black
                band.mask = run
                container.addSublayer(band)
            }
            bottom.isHidden = bottomEdges == nil
        }
    }

    // The reflection tracks real playback only: letting the seek preview reach it made the strip flicker.
    private let tones = [
        Tone(top: (.dim, .end), bottom: (.played, .end)),
        Tone(top: (.solid, .dim), bottom: nil),
        Tone(top: (.start, .solid), bottom: (.start, .played)),
        Tone(top: (.start, .end), bottom: (.start, .end)),
    ]
    private var lit: Tone { tones[3] }
    private let canvas = CALayer()

    private var waveform: Waveform?
    private var palette: Palette?
    private var motion: Motion?
    private var scale: CGFloat = 2
    private var drawnKey: BarsKey?
    private var drawing = 0
    private var awaitsPeaks = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        canvas.isGeometryFlipped = true
        canvas.opacity = 0
        for tone in tones { canvas.addSublayer(tone.container) }
        lit.container.opacity = 0
        layer?.addSublayer(canvas)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        quietly {
            canvas.frame = bounds
            let split = WaveformView.barsBottom(in: bounds.height) + WaveformView.centreGap / 2
            for tone in tones {
                tone.container.frame = canvas.bounds
                tone.bars.frame = canvas.bounds
                tone.top.frame = CGRect(x: 0, y: 0, width: bounds.width, height: split)
                tone.bottom.frame = CGRect(x: 0, y: split, width: bounds.width, height: bounds.height - split)
            }
        }
        drawBars()
        if let motion { place(motion) }
    }

    func show(_ waveform: Waveform?, palette: Palette, scale: CGFloat) {
        if palette != self.palette {
            self.palette = palette
            quietly {
                let colours: [(CGColor, CGColor?)] = [palette.remaining, (palette.preview, nil), palette.played, palette.lit]
                for (tone, colour) in zip(tones, colours) {
                    tone.top.backgroundColor = colour.0
                    tone.bottom.backgroundColor = colour.1
                }
            }
        }
        let peaksChanged = waveform?.peaks != self.waveform?.peaks
        self.waveform = waveform
        self.scale = scale
        if peaksChanged || waveform == nil { drawBars() }
    }

    func run(_ motion: Motion) {
        guard motion != self.motion else { return }
        self.motion = motion
        place(motion)
    }

    func light(_ highlight: Double, animated: Bool) {
        let target = Float(min(max(highlight, 0), 1))
        guard lit.container.opacity != target else { return }
        let from = lit.container.presentation()?.opacity ?? lit.container.opacity
        quietly { lit.container.opacity = target }
        guard animated else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = target
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        lit.container.add(fade, forKey: "light")
    }

    // MARK: - Runs

    private func place(_ motion: Motion) {
        let width = bounds.width
        guard width > 0 else { return }
        let span = WaveformView.barsSpan(in: width)
        func x(_ fraction: Double) -> CGFloat { fraction >= 1 ? width : span * CGFloat(max(fraction, 0)) }

        let playhead = motion.playhead
        let hover = motion.hover
        let now = playhead.progress(at: .now)
        var stops = [now]
        let runs = playhead.isRunning && now < 1
        if runs {
            if hover > now { stops.append(hover) }
            stops.append(1)
        }
        let duration = runs ? (1 - now) * playhead.duration / playhead.rate : 0
        let keyTimes = stops.map { NSNumber(value: runs ? ($0 - now) / (1 - now) : 0) }

        quietly {
            for tone in tones {
                for (run, edges, band) in [(tone.topRun, tone.topEdges, tone.top),
                                           (tone.bottomRun, tone.bottomEdges, tone.bottom)] {
                    guard let edges else { continue }
                    let lows = stops.map { x(edges.0.at($0, hover: hover)) }
                    let highs = stops.map { x(edges.1.at($0, hover: hover)) }
                    let widths = zip(lows, highs).map { max($1 - $0, 0) }
                    run.removeAnimation(forKey: "run")
                    run.position = CGPoint(x: lows[0], y: 0)
                    run.bounds = CGRect(x: 0, y: 0, width: widths[0], height: band.bounds.height)
                    guard runs else { continue }
                    let slide = CAKeyframeAnimation(keyPath: "position.x")
                    slide.values = lows
                    let grow = CAKeyframeAnimation(keyPath: "bounds.size.width")
                    grow.values = widths
                    let group = CAAnimationGroup()
                    for part in [slide, grow] {
                        part.keyTimes = keyTimes
                        part.calculationMode = .linear
                    }
                    group.animations = [slide, grow]
                    group.duration = duration
                    group.fillMode = .forwards
                    group.isRemovedOnCompletion = false
                    run.add(group, forKey: "run")
                }
            }
        }
    }

    // MARK: - Bars

    private struct BarsKey: Hashable {
        let peaks: [Float]
        let width: Int
        let height: Int
    }

    private struct Drawing: @unchecked Sendable {
        let image: CGImage
    }

    // A list scrolled back over the same tracks finds their bars drawn.
    private static var drawings: [BarsKey: CGImage] = [:]
    private static var drawingOrder: [BarsKey] = []
    private static let keptDrawings = 48

    private func drawBars() {
        guard let waveform, bounds.width > 0, bounds.height > 0 else {
            drawnKey = nil
            awaitsPeaks = waveform == nil
            quietly {
                canvas.opacity = 0
                for tone in tones { tone.bars.contents = nil }
            }
            return
        }
        let key = BarsKey(peaks: waveform.peaks,
                          width: Int((bounds.width * scale).rounded()), height: Int((bounds.height * scale).rounded()))
        guard key != drawnKey else { return }
        drawnKey = key
        drawing += 1
        if let image = Self.drawings[key] {
            present(image, for: key)
        } else if !ScrollActivity.isLive {
            Self.rasterise(waveform, width: key.width, height: key.height, scale: scale).map { present($0.image, for: key) }
        } else {
            // Off the main thread mid-flick: a new strip costs about a millisecond to rasterise.
            let ticket = drawing
            let scale = scale
            Task {
                guard let drawn = await Self.rasteriseApart(waveform, width: key.width, height: key.height, scale: scale),
                      ticket == drawing else { return }
                present(drawn.image, for: key)
            }
        }
    }

    private func present(_ image: CGImage, for key: BarsKey) {
        if Self.drawings.updateValue(image, forKey: key) == nil {
            Self.drawingOrder.append(key)
            if Self.drawingOrder.count > Self.keptDrawings { Self.drawings[Self.drawingOrder.removeFirst()] = nil }
        }
        quietly {
            for tone in tones {
                tone.bars.contents = image
                tone.bars.contentsScale = scale
            }
            canvas.opacity = 1
        }
        guard awaitsPeaks else { return }
        awaitsPeaks = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.25
        canvas.add(fade, forKey: "appear")
    }

    @concurrent
    nonisolated private static func rasteriseApart(_ waveform: Waveform, width: Int, height: Int,
                                                   scale: CGFloat) async -> Drawing? {
        rasterise(waveform, width: width, height: height, scale: scale)
    }

    // A bar at a time: CoreGraphics filled one path of every rounded bar 15 times slower.
    nonisolated private static func rasterise(_ waveform: Waveform, width: Int, height: Int, scale: CGFloat) -> Drawing? {
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)

        let size = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        let slot = WaveformView.barWidth + WaveformView.barSpacing
        let bars = waveform.resampled(to: max(Int(size.width / slot), 1))
        let topHeight = WaveformView.barsBottom(in: size.height)
        let bottomHeight = size.height - WaveformView.centreGap - topHeight
        let radius = WaveformView.barWidth / 2
        func fill(_ rect: CGRect) {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: min(radius, rect.height / 2),
                                   transform: nil))
            context.fillPath()
        }
        for (index, bar) in bars.enumerated() {
            let x = CGFloat(index) * slot
            let rise = max(CGFloat(bar) * topHeight, 2)
            let drop = max(CGFloat(bar) * bottomHeight, 1)
            fill(CGRect(x: x, y: topHeight - rise, width: WaveformView.barWidth, height: rise))
            fill(CGRect(x: x, y: topHeight + WaveformView.centreGap, width: WaveformView.barWidth, height: drop))
        }
        return context.makeImage().map(Drawing.init)
    }

    private func quietly(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}
