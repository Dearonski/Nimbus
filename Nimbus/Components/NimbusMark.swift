import SwiftUI

/// Proportions of the app's mark — a capital N whose two stems are mixer faders. Every value is a
/// fraction of the mark's square box, measured off the reference render rather than guessed.
nonisolated enum FaderN {
    static let stroke: CGFloat = 0.142
    static let stemX: (left: CGFloat, right: CGFloat) = (0.178, 0.822)
    static let knob = CGSize(width: 0.357, height: 0.142)
    /// Knobs sit clear of the diagonal, which runs high on the left stem and low on the right one.
    static let knobY: (left: CGFloat, right: CGFloat) = (0.715, 0.286)
    /// The stem is cut where a knob crosses it, leaving the plate visible either side — that gap is
    /// what makes the caps read as knobs riding a track rather than tape stuck over a bar.
    static let knobGap: CGFloat = 0.037

    static func box(in rect: CGRect) -> CGRect {
        let side = min(rect.width, rect.height)
        return CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    }
}

/// The letter itself: two capsule stems joined by a diagonal of the same weight.
struct FaderNLetter: Shape {
    func path(in rect: CGRect) -> Path {
        let box = FaderN.box(in: rect)
        let side = box.width
        let weight = side * FaderN.stroke

        func stem(_ x: CGFloat) -> CGPath {
            CGPath(roundedRect: CGRect(x: box.minX + side * x - weight / 2, y: box.minY,
                                       width: weight, height: side),
                   cornerWidth: weight / 2, cornerHeight: weight / 2, transform: nil)
        }

        let diagonal = Path { path in
            path.move(to: CGPoint(x: box.minX + side * FaderN.stemX.left, y: box.minY + weight / 2))
            path.addLine(to: CGPoint(x: box.minX + side * FaderN.stemX.right, y: box.maxY - weight / 2))
        }
        .strokedPath(StrokeStyle(lineWidth: weight, lineCap: .round))

        let cutHeight = side * (FaderN.knob.height + FaderN.knobGap * 2)
        func cut(_ x: CGFloat, _ y: CGFloat) -> CGPath {
            CGPath(rect: CGRect(x: box.minX + side * x - weight / 2,
                                y: box.minY + side * y - cutHeight / 2,
                                width: weight, height: cutHeight),
                   transform: nil)
        }

        return Path(diagonal.cgPath
            .union(stem(FaderN.stemX.left))
            .union(stem(FaderN.stemX.right))
            .subtracting(cut(FaderN.stemX.left, FaderN.knobY.left))
            .subtracting(cut(FaderN.stemX.right, FaderN.knobY.right)))
    }
}

/// The two knob caps, drawn separately so they can carry the accent colour.
struct FaderNKnobs: Shape {
    func path(in rect: CGRect) -> Path {
        let box = FaderN.box(in: rect)
        let side = box.width
        let size = CGSize(width: side * FaderN.knob.width, height: side * FaderN.knob.height)

        var path = Path()
        for (x, y) in [(FaderN.stemX.left, FaderN.knobY.left), (FaderN.stemX.right, FaderN.knobY.right)] {
            let frame = CGRect(x: box.minX + side * x - size.width / 2,
                               y: box.minY + side * y - size.height / 2,
                               width: size.width, height: size.height)
            path.addRoundedRect(in: frame, cornerSize: CGSize(width: size.height * 0.3,
                                                              height: size.height * 0.3))
        }
        return path
    }
}

struct NimbusMark: View {
    var letter: Color = .nimbusBone
    var knob: Color = .scOrange

    var body: some View {
        ZStack {
            FaderNLetter().fill(letter)
            FaderNKnobs().fill(knob)
        }
    }
}

/// The mark on its plate. The icon that ships is square and unmasked — the system rounds it — so
/// `cornerRadius` stays at zero everywhere except on-screen uses like the welcome screen.
struct MarkTile: View {
    var size: CGFloat = 104
    var cornerRadius: CGFloat = 0
    /// Share of the plate the mark spans, caps included.
    var fill: CGFloat = 0.70
    var ground: Color = .nimbusInk
    var letter: Color = .nimbusBone
    var knob: Color = .scOrange

    var body: some View {
        ZStack {
            Rectangle().fill(ground)
            NimbusMark(letter: letter, knob: knob)
                .frame(width: size * fill, height: size * fill)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
