import SwiftUI

/// SoundCloud's "next up" mark: a play triangle with one short line beside it, then two full ones.
/// SF's `text.line.first.and.arrowtriangle.forward` is the same idea drawn with four lines, which
/// reads as a paragraph. Proportions are the site's own 16pt grid, normalised.
nonisolated struct QueueMark: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let originX = rect.minX + (rect.width - side) / 2
        let originY = rect.minY + (rect.height - side) / 2
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x / 16 * side, y: originY + y / 16 * side)
        }
        func bar(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
            CGRect(origin: point(x0, y0),
                   size: CGSize(width: (x1 - x0) / 16 * side, height: (y1 - y0) / 16 * side))
        }

        var path = Path()
        path.move(to: point(1, 1.98))
        path.addLine(to: point(4.32, 4))
        path.addLine(to: point(1, 6.02))
        path.closeSubpath()

        let radius = 0.75 / 16 * side
        for line in [bar(7, 3.25, 15, 4.75), bar(1, 8.375, 15, 9.875), bar(1, 13.5, 15, 15)] {
            path.addRoundedRect(in: line, cornerSize: CGSize(width: radius, height: radius))
        }
        return path
    }
}

/// SoundCloud's repeat mark: a flat loop, broken at the bottom left where the arrowhead points
/// back the way the track came. SF's `repeat` is two crossing arrows that turn to mush at player
/// size, and `arrow.triangle.capsulepath` stands the same loop on end with the head in the wrong
/// corner — hence drawing it. Geometry is the web player's own 16pt grid, read off its markup:
/// loop 1.25…14.75 by 3.25…12.75 with a 1.5 wall, arrowhead from (4.97, 9.47) to (2.44, 12).
nonisolated struct RepeatMark: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let originX = rect.minX + (rect.width - side) / 2
        let originY = rect.minY + (rect.height - side) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x / 16 * side, y: originY + y / 16 * side)
        }

        var path = Path()
        path.move(to: p(1.25, 8))
        path.addCurve(to: p(6, 3.25), control1: p(1.25, 5.3767), control2: p(3.3767, 3.25))
        path.addLine(to: p(10, 3.25))
        path.addCurve(to: p(14.75, 8), control1: p(12.6233, 3.25), control2: p(14.75, 5.3767))
        path.addCurve(to: p(10, 12.75), control1: p(14.75, 10.6233), control2: p(12.6233, 12.75))
        path.addLine(to: p(5.3107, 12.75))
        path.addLine(to: p(6.0303, 13.4697))
        path.addLine(to: p(4.9697, 14.5303))
        path.addLine(to: p(2.4393, 12))
        path.addLine(to: p(4.9697, 9.4697))
        path.addLine(to: p(6.0303, 10.5303))
        path.addLine(to: p(5.3107, 11.25))
        path.addLine(to: p(10, 11.25))
        path.addCurve(to: p(13.25, 8), control1: p(11.7949, 11.25), control2: p(13.25, 9.7949))
        path.addCurve(to: p(10, 4.75), control1: p(13.25, 6.2051), control2: p(11.7949, 4.75))
        path.addLine(to: p(6, 4.75))
        path.addCurve(to: p(2.75, 8), control1: p(4.2051, 4.75), control2: p(2.75, 6.2051))
        path.addCurve(to: p(3.0772, 9.4228), control1: p(2.75, 8.5103), control2: p(2.8676, 8.9931))
        path.addLine(to: p(1.9756, 10.5244))
        path.addCurve(to: p(1.25, 8), control1: p(1.5159, 9.7931), control2: p(1.25, 8.9276))
        path.closeSubpath()
        return path
    }
}

#if DEBUG
#Preview("Glyph sizing") {
    // Each glyph alone in a 40pt cell, so a pixel measurement of the render says how much of the
    // cell it actually fills — that is what "the same size" means next to an SF symbol.
    HStack(spacing: 0) {
        Group {
            Image(systemName: "shuffle").font(.system(size: 15))
            RepeatMark().frame(width: 19, height: 19)
            Image(systemName: "heart.fill").font(.system(size: 17))
            QueueMark().frame(width: 18, height: 18)
            Image(systemName: "speaker.wave.2.fill").font(.system(size: 17))
        }
        .frame(width: 40, height: 40)
    }
    .foregroundStyle(.white)
    .background(Color.black)
}

#Preview("Player glyphs") {
    HStack(spacing: 30) {
        VStack(spacing: 10) {
            QueueMark().frame(width: 44, height: 44)
            QueueMark().frame(width: 17, height: 17)
            Text("QueueMark").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        VStack(spacing: 10) {
            RepeatMark().frame(width: 44, height: 44)
            RepeatMark().frame(width: 17, height: 17)
            Text("RepeatMark").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        VStack(spacing: 10) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward").font(.system(size: 36))
            Image(systemName: "repeat").font(.system(size: 36))
            Text("SF, for scale").font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
    .padding(30)
    .background(Color(nsColor: .windowBackgroundColor))
    .foregroundStyle(.primary)
}
#endif
