import AppKit
import Nuke
import SwiftUI

/// The cover as the label; the disc turns under a highlight that stays put, as under a lamp.
struct VinylRecord: View {
    nonisolated static let holeRatio: CGFloat = 0.018

    let track: SCTrack?
    // In turns of 33⅓ rpm, so 1 is a record playing at normal speed.
    var rate: Double = 0
    // Degrees turned by hand since the record was grabbed.
    var hold: Double?

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                VinylDisc(track: track, rate: rate, hold: hold)
                Circle()
                    .fill(AngularGradient(colors: [.clear, .white.opacity(0.14), .clear, .clear,
                                                   .white.opacity(0.09), .clear, .clear],
                                          center: .center, angle: .degrees(-35)))
                    // Off the label: the sheen is the vinyl's, and paper doesn't shine.
                    .mask {
                        Circle().fill(RadialGradient(colors: [.clear, .clear, .white, .white],
                                                     center: .center, startRadius: 0, endRadius: side / 2))
                    }
                    .blendMode(.screen)
                    .allowsHitTesting(false)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// The disc's outline with the spindle hole through it, so what lies under the record shows through as well.
struct VinylRecordShape: Shape {
    nonisolated static func path(in rect: CGRect) -> CGPath {
        let side = min(rect.width, rect.height)
        let dot = side * VinylRecord.holeRatio
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
        path.addEllipse(in: CGRect(x: rect.midX - dot / 2, y: rect.midY - dot / 2, width: dot, height: dot))
        return path
    }

    nonisolated func path(in rect: CGRect) -> Path { Path(Self.path(in: rect)) }
}

struct SpinningVinyl: View {
    let track: SCTrack?
    let playhead: Playhead
    var hold: Double?

    var body: some View {
        VinylRecord(track: track, rate: playhead.isRunning ? playhead.rate : 0, hold: hold)
    }
}

// Turned by Core Animation: a SwiftUI frame per angle relaid the full player out 120 times a second.
private struct VinylDisc: NSViewRepresentable {
    let track: SCTrack?
    let rate: Double
    let hold: Double?

    func makeNSView(context: Context) -> VinylDiscView { VinylDiscView() }

    func updateNSView(_ view: VinylDiscView, context: Context) {
        view.scale = context.environment.displayScale
        view.show(track)
        view.turn(rate: rate, hold: hold)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: VinylDiscView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

private final class VinylDiscView: NSView {
    // A 12-inch disc carries a label of about four inches.
    private static let labelRatio: CGFloat = 0.33
    private static let degreesPerSecond = 200.0

    var scale: CGFloat = 2

    private let disc = CALayer()
    private let grooves = CALayer()
    private let label = CALayer()
    private let shade = CAGradientLayer()
    // Cut through rather than filled: a painted dot glowed against every backdrop but a light one.
    private let hole = CAShapeLayer()
    // The label's cut edge, lit from above like the disc's sheen, so it holds still while the record turns.
    private let rim = CAGradientLayer()
    private let rimShape = CAShapeLayer()

    private var trackID: Int?
    private var loading: Task<Void, Never>?
    private var groovesSide: CGFloat = 0

    private struct Spin {
        var start: CFTimeInterval
        var angle: Double
        var speed: Double
        var target: Double

        // About 0.4 s to come up to speed and 0.8 s to coast to a stop.
        var lag: Double { target > speed ? 0.12 : 0.25 }
        var settles: Double { abs(target - speed) < 0.001 ? 0 : lag * 6 }

        func angle(at time: CFTimeInterval) -> Double {
            let t = max(time - start, 0)
            return angle + VinylDiscView.degreesPerSecond * (target * t + (speed - target) * lag * (1 - exp(-t / lag)))
        }

        func speed(at time: CFTimeInterval) -> Double {
            target + (speed - target) * exp(-max(time - start, 0) / lag)
        }
    }

    private var spin: Spin?
    private var grabbedAt: Double?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(disc)
        disc.addSublayer(grooves)
        disc.addSublayer(label)
        disc.addSublayer(shade)
        hole.fillRule = .evenOdd
        disc.mask = hole
        layer?.addSublayer(rim)
        rim.colors = [NSColor(white: 1, alpha: 0.3).cgColor, NSColor(white: 1, alpha: 0.06).cgColor]
        rim.startPoint = CGPoint(x: 0.5, y: 0)
        rim.endPoint = CGPoint(x: 0.5, y: 1)
        rimShape.fillColor = nil
        rimShape.strokeColor = .black
        rim.mask = rimShape
        label.contentsGravity = .resizeAspectFill
        label.masksToBounds = true
        // Paper darkens toward the rim where the press squeezed it.
        shade.type = .radial
        shade.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.35).cgColor]
        shade.locations = [0, 0.5, 1]
        shade.startPoint = CGPoint(x: 0.5, y: 0.5)
        shade.endPoint = CGPoint(x: 1, y: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        grooves.frame = disc.bounds
        let labelSide = side * Self.labelRatio
        for layer in [label, shade] {
            layer.frame = CGRect(x: (side - labelSide) / 2, y: (side - labelSide) / 2, width: labelSide, height: labelSide)
            layer.cornerRadius = labelSide / 2
        }
        hole.frame = disc.bounds
        hole.path = VinylRecordShape.path(in: disc.bounds)
        let dot = side * VinylRecord.holeRatio
        let edge = side * 0.0022
        rim.frame = CGRect(x: bounds.midX - dot / 2 - edge, y: bounds.midY - dot / 2 - edge,
                           width: dot + edge * 2, height: dot + edge * 2)
        rimShape.frame = rim.bounds
        rimShape.lineWidth = edge
        rimShape.path = CGPath(ellipseIn: rim.bounds.insetBy(dx: edge / 2, dy: edge / 2), transform: nil)
        for layer in [hole, rim, rimShape] { layer.contentsScale = scale }
        CATransaction.commit()
        if groovesSide != side {
            groovesSide = side
            grooves.contents = Self.drawGrooves(side: side, scale: scale)
            grooves.contentsScale = scale
        }
    }

    // MARK: - Label

    func show(_ track: SCTrack?) {
        guard track?.id != trackID else { return }
        trackID = track?.id
        loading?.cancel()
        let mid = track?.coverURL.liveArtwork.scArtwork(.mid)
        let hero = track?.coverURL.liveArtwork.scArtwork(.hero)
        // The pill's cover is already cached, so the label is never blank while the larger one loads.
        if let mid, let cached = ImagePipeline.shared.cache[ImageRequest(url: mid)] {
            label.contents = cached.image
        } else {
            label.contents = track.flatMap { Self.fallback(for: $0) }
        }
        guard let hero, !DeadArtwork.contains(hero) else { return }
        loading = Task { [weak self] in
            do {
                let image = try await ImagePipeline.shared.image(for: hero)
                guard !Task.isCancelled else { return }
                self?.label.contents = image
            } catch {
                DeadArtwork.record(error, for: hero)
            }
        }
    }

    private static func fallback(for track: SCTrack) -> CGImage? {
        let renderer = ImageRenderer(content: SCGradient(index: SCGradient.index(for: track.id)).frame(width: 64, height: 64))
        return renderer.cgImage
    }

    // MARK: - Turning

    func turn(rate: Double, hold: Double?) {
        let now = CACurrentMediaTime()
        if let hold {
            // Under a hand the platter stops dead and the record goes where it is pushed.
            let grabbed = grabbedAt ?? spin?.angle(at: now) ?? 0
            grabbedAt = grabbed
            spin = Spin(start: now, angle: grabbed + hold, speed: 0, target: 0)
            disc.removeAllAnimations()
            set(grabbed + hold)
            return
        }
        if grabbedAt != nil {
            grabbedAt = nil
            let released = Spin(start: now, angle: spin?.angle ?? 0, speed: 0, target: rate)
            spin = released
            run(released)
            return
        }
        if let spin, spin.target == rate { return }
        // Opened on a record already playing: it should be turning from the first frame, not spin up.
        let next = Spin(start: now, angle: (spin?.angle(at: now) ?? 0).truncatingRemainder(dividingBy: 360),
                        speed: spin?.speed(at: now) ?? rate, target: rate)
        spin = next
        run(next)
    }

    private func run(_ spin: Spin) {
        disc.removeAllAnimations()
        let settles = spin.settles
        let settled = spin.angle(at: spin.start + settles)
        set(settled)
        if settles > 0 {
            let steps = 24
            let change = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            change.values = (0...steps).map { radians(spin.angle(at: spin.start + settles * Double($0) / Double(steps))) }
            change.duration = settles
            change.beginTime = spin.start
            change.calculationMode = .linear
            disc.add(change, forKey: "change")
        }
        guard spin.target > 0 else { return }
        let steady = CABasicAnimation(keyPath: "transform.rotation.z")
        steady.fromValue = radians(settled)
        steady.toValue = radians(settled + 360)
        steady.duration = 360 / (Self.degreesPerSecond * spin.target)
        steady.repeatCount = .infinity
        steady.beginTime = spin.start + settles
        disc.add(steady, forKey: "steady")
    }

    private func set(_ degrees: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.setValue(radians(degrees), forKeyPath: "transform.rotation.z")
        CATransaction.commit()
    }

    // Clockwise, as the record turns on the platter; the layer's own axis runs the other way.
    private func radians(_ degrees: Double) -> Double { -degrees * .pi / 180 }

    // MARK: - Grooves

    private static func drawGrooves(side: CGFloat, scale: CGFloat) -> CGImage? {
        let pixels = Int((side * scale).rounded())
        guard pixels > 0,
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let radius = side / 2
        let centre = CGPoint(x: radius, y: radius)
        context.setFillColor(NSColor(white: 0.06, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
        context.setLineWidth(0.6)
        var ring = radius * 0.97
        var index = 0
        while ring > radius * 0.35 {
            let gap = abs(ring / radius - 0.72) < 0.008 || abs(ring / radius - 0.55) < 0.008
            context.setStrokeColor(NSColor(white: 1, alpha: gap ? 0.02 : (index % 2 == 0 ? 0.085 : 0.04)).cgColor)
            context.strokeEllipse(in: CGRect(x: centre.x - ring, y: centre.y - ring, width: ring * 2, height: ring * 2))
            ring -= gap ? 2.4 : 1.3
            index += 1
        }
        return context.makeImage()
    }
}
