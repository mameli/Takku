import Foundation

/// The time since `start` for the timing logs, e.g. "12.3s".
func secondsSince(_ start: ContinuousClock.Instant) -> String {
    let elapsed = (ContinuousClock.now - start).components
    return String(format: "%.1fs", Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
}
