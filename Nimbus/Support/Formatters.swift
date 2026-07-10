import Foundation

func countString(_ n: Int) -> String {
    let value: Double
    let suffix: String
    if n >= 1_000_000 { value = Double(n) / 1_000_000; suffix = "M" }
    else if n >= 1_000 { value = Double(n) / 1_000; suffix = "K" }
    else { return "\(n)" }
    return (value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)) + suffix
}

func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}

func longDurationString(ms: Int) -> String {
    let minutes = ms / 60_000
    guard minutes >= 60 else { return "\(minutes) min" }
    return minutes % 60 == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(minutes % 60) min"
}
