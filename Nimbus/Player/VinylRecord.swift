import SwiftUI

/// The cover as the label; the disc turns under a highlight that stays put, as under a lamp.
struct VinylRecord: View {
    let track: SCTrack?
    var angle: Angle = .zero

    /// A 12-inch disc carries a label of about four inches.
    private static let labelRatio: CGFloat = 0.33

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                ZStack {
                    VinylGrooves().equatable()
                    ZStack {
                        Artwork(track, size: .mid)
                        Artwork(track, size: .hero, placeholderOpacity: 0)
                    }
                        .overlay {
                            // Paper darkens toward the rim where the press squeezed it.
                            RadialGradient(colors: [.clear, .clear, .black.opacity(0.35)],
                                           center: .center, startRadius: 0, endRadius: side * Self.labelRatio / 2)
                        }
                        .frame(width: side * Self.labelRatio, height: side * Self.labelRatio)
                        .clipShape(Circle())
                    Circle()
                        .fill(Color(white: 0.85))
                        .frame(width: side * 0.018, height: side * 0.018)
                }
                .rotationEffect(angle)

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

/// Equatable with nothing to compare, so turning the record never draws the grooves again.
private struct VinylGrooves: View, Equatable {
    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = size.width / 2
            context.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.06)))
            var ring = radius * 0.97
            var index = 0
            while ring > radius * 0.35 {
                let gap = abs(ring / radius - 0.72) < 0.008 || abs(ring / radius - 0.55) < 0.008
                let rect = CGRect(x: centre.x - ring, y: centre.y - ring, width: ring * 2, height: ring * 2)
                context.stroke(Path(ellipseIn: rect),
                               with: .color(.white.opacity(gap ? 0.02 : (index % 2 == 0 ? 0.085 : 0.04))),
                               lineWidth: 0.6)
                ring -= gap ? 2.4 : 1.3
                index += 1
            }
        }
    }
}

/// 33⅓ rpm times the real rate, integrated from it rather than read off the position, so seeks don't jolt it.
struct SpinningVinyl: View {
    let track: SCTrack?
    let playhead: Playhead
    /// Degrees turned by hand since the record was grabbed; nil while nobody holds it.
    var hold: Double?

    @State private var spin = VinylSpin()
    /// Keeps the frames coming while the record winds down after the sound has stopped.
    @State private var coasting = false

    var body: some View {
        TimelineView(.animation(paused: !playhead.isRunning && !coasting)) { timeline in
            let rate = playhead.isRunning ? playhead.rate : 0
            VinylRecord(track: track, angle: .degrees(spin.advance(to: timeline.date, rate: rate, hold: hold)))
        }
        .onChange(of: playhead.isRunning) { _, running in
            guard !running else { return }
            coasting = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                coasting = false
            }
        }
    }
}

private final class VinylSpin {
    private static let degreesPerSecond = 200.0
    private var degrees = 0.0
    /// In turns of 33⅓ rpm, so 1 is a record playing at normal speed.
    private var velocity = 0.0
    private var last: Date?
    /// What the hand turned it by, folded into the angle once it lets go.
    private var turned = 0.0

    func advance(to date: Date, rate: Double, hold: Double?) -> Double {
        defer { last = date }
        // Under a hand the platter stops dead and the record goes where it is pushed.
        if let hold {
            velocity = 0
            turned = hold
            return degrees + hold
        }
        if turned != 0 {
            degrees += turned
            turned = 0
        }
        // Opened on a record already playing: it should be turning from the first frame, not spin up.
        guard let last else {
            velocity = rate
            return degrees
        }
        let step = min(max(date.timeIntervalSince(last), 0), 0.1)
        // About 0.4 s to come up to speed and 0.8 s to coast to a stop.
        let lag = rate > velocity ? 0.12 : 0.25
        velocity += (rate - velocity) * (1 - exp(-step / lag))
        degrees = (degrees + velocity * Self.degreesPerSecond * step).truncatingRemainder(dividingBy: 360)
        return degrees
    }
}
