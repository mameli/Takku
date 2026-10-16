import Foundation

/// The time since `start` for the timing logs, e.g. "12.3s".
func secondsSince(_ start: ContinuousClock.Instant) -> String {
    String(format: "%.1fs", (ContinuousClock.now - start) / .seconds(1))
}
