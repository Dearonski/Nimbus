import AppKit
import SwiftUI

// A SwiftUI tick inside the pill's glass restarts the glass's spring, so the window redrew nonstop.
struct PlayheadFill: NSViewRepresentable {
    let playhead: Playhead

    func makeNSView(context: Context) -> FillView { FillView() }

    func updateNSView(_ view: FillView, context: Context) {
        view.run(playhead)
    }

    final class FillView: NSView {
        private let fill = CALayer()
        private var applied: Playhead?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            fill.anchorPoint = CGPoint(x: 0, y: 0.5)
            fill.backgroundColor = NSColor(.scOrange).cgColor
            layer?.addSublayer(fill)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.cornerRadius = bounds.height / 2
            fill.bounds = bounds
            fill.position = CGPoint(x: 0, y: bounds.midY)
            CATransaction.commit()
        }

        func run(_ playhead: Playhead) {
            guard playhead != applied else { return }
            applied = playhead
            let start = playhead.progress(at: .now)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.removeAnimation(forKey: "run")
            fill.transform = CATransform3DMakeScale(start, 1, 1)
            if playhead.isRunning, start < 1 {
                let run = CABasicAnimation(keyPath: "transform.scale.x")
                run.fromValue = start
                run.toValue = 1
                run.duration = (1 - start) * playhead.duration / playhead.rate
                run.timingFunction = CAMediaTimingFunction(name: .linear)
                run.fillMode = .forwards
                run.isRemovedOnCompletion = false
                fill.add(run, forKey: "run")
            }
            CATransaction.commit()
        }
    }
}
