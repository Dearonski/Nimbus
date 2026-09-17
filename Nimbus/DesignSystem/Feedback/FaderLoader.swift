import SwiftUI

/// The app's own busy indicator: the mark's faders, riding their tracks. The knob is 2.5× the rail
/// it slides on, the same ratio the logo uses, so the two read as one object.
struct FaderLoader: View {
    var size: CGFloat = 16
    var rail: Color = Color.secondary.opacity(0.32)
    var knob: Color = .scOrange
    /// Preview only: pins the cycle at one point, since a still frame can't show the ends of the
    /// throw and the loader would otherwise only ever be caught mid-sweep.
    var phaseOverride: Double?

    /// Three is the fewest that reads as a mixer rather than a pair of sliders.
    private static let count = 3
    private static let period: Double = 1.5

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, canvasSize in
                let time = phaseOverride.map { $0 * Self.period }
                    ?? timeline.date.timeIntervalSinceReferenceDate
                draw(context, canvasSize, at: time)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Loading")
    }

    private func draw(_ context: GraphicsContext, _ canvasSize: CGSize, at time: TimeInterval) {
        let side = min(canvasSize.width, canvasSize.height)
        let mid = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        // Rail, gap and knob together span the box exactly at these fractions; changing one alone
        // either crowds the knobs or leaves the row floating inside its frame.
        let railWidth = side * 0.11
        let knobSize = CGSize(width: railWidth * 2.5, height: railWidth)
        let step = side * 0.363
        // The knobs stop well short of the ends, travelling between the two positions the mark's
        // own knobs hold — a cap running into the end of its rail reads as broken, not as loading.
        let travel = side * (FaderN.knobY.left - FaderN.knobY.right) / 2

        for index in 0..<Self.count {
            let x = mid.x + step * (CGFloat(index) - 1)

            let railRect = CGRect(x: x - railWidth / 2, y: mid.y - side / 2,
                                  width: railWidth, height: side)
            context.fill(Path(roundedRect: railRect, cornerRadius: railWidth / 2), with: .color(rail))

            // Sinusoidal, not linear: a fader eases at the ends of its throw.
            let phase = time / Self.period + Double(index) / Double(Self.count)
            let y = mid.y + travel * CGFloat(sin(phase * 2 * .pi))
            let knobRect = CGRect(x: x - knobSize.width / 2, y: y - knobSize.height / 2,
                                  width: knobSize.width, height: knobSize.height)
            context.fill(Path(roundedRect: knobRect, cornerRadius: knobSize.height * 0.3),
                         with: .color(knob))
        }
    }
}

#if DEBUG
#Preview("Fader loader") {
    VStack(spacing: 32) {
        HStack(spacing: 28) {
            FaderLoader(size: 14)
            FaderLoader(size: 18)
            FaderLoader(size: 28)
            FaderLoader(size: 56)
            ZStack {
                Circle().fill(.tint).frame(width: 40, height: 40)
                FaderLoader(size: 17, rail: .white.opacity(0.45), knob: .white)
            }
        }

        // One full cycle, so the ends of the throw are visible in a still.
        HStack(spacing: 20) {
            ForEach(0..<9, id: \.self) { step in
                FaderLoader(size: 44, phaseOverride: Double(step) / 8)
            }
        }
    }
    .padding(40)
}
#endif
