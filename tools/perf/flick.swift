import AppKit

// usage: flick <pid> down|top|probe — trackpad-like scroll gestures into the app's main window.
// Posted at the HID tap with the cursor warped over the window: events posted to the pid never reached it.
let pid = pid_t(CommandLine.arguments[1])!
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "down"

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
guard let bounds = windows.lazy.filter({
    ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
}).compactMap({ $0[kCGWindowBounds as String] as? [String: CGFloat] }).first(where: { ($0["Height"] ?? 0) > 500 })
else { print("no window"); exit(1) }
let point = CGPoint(x: bounds["X"]! + bounds["Width"]! * 0.55, y: bounds["Y"]! + bounds["Height"]! * 0.5)

func post(_ delta: Int32, phase: Int64 = 0, momentum: Int64 = 0) {
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                        wheel1: delta, wheel2: 0, wheel3: 0)!
    event.location = point
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(delta))
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(delta))
    event.post(tap: .cghidEventTap)
}

func wait(_ ms: Double) { usleep(useconds_t(ms * 1000)) }

func flick(_ direction: Int32, stroke: Int32 = 36, strokes: Int = 10, momentumFrames: Int = 70) {
    post(0, phase: 1)
    for _ in 0..<strokes { wait(8); post(direction * stroke, phase: 2) }
    wait(8); post(0, phase: 4)
    var speed = Double(stroke) * 2
    post(direction * Int32(speed), momentum: 1)
    for _ in 0..<momentumFrames { wait(16); speed *= 0.94; post(direction * Int32(max(speed, 1)), momentum: 2) }
    post(0, momentum: 3)
}

let home = CGEvent(source: nil)?.location ?? point
CGWarpMouseCursorPosition(point)
defer { CGWarpMouseCursorPosition(home) }
wait(50)

switch mode {
case "top":
    for _ in 0..<40 { flick(1, stroke: 400, strokes: 5, momentumFrames: 0) }
case "probe":
    flick(-1, strokes: 3, momentumFrames: 5)
default:
    wait(300)
    for _ in 0..<3 { flick(-1); wait(300) }
}
