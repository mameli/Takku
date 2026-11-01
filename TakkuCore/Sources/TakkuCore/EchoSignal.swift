import Foundation

/// The level of both Tracks every 20 ms on the Meeting timeline, to tell whether a stretch of the
/// Me Track is the others' voice coming back from the speakers (bleed) or someone speaking in the
/// room (local). When the call plays through speakers the microphone hears it tens of
/// milliseconds after the system audio carries it, fainter: what the delayed, attenuated Others
/// Track explains is bleed; sound well above it is local, even while the others speak at the same
/// time.
///
/// Ported from Hex, `src/meeting/echo.rs` (https://github.com/anomalyco/hex), under the MIT License:
/// Copyright (c) 2026 Christopher Langton. Permission is hereby granted, free of charge, to any
/// person obtaining a copy of this software and associated documentation files (the "Software"),
/// to deal in the Software without restriction, including without limitation the rights to use,
/// copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
/// to permit persons to whom the Software is furnished to do so, subject to the following
/// conditions: the above copyright notice and this permission notice shall be included in all
/// copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT
/// WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
/// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
/// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
/// OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
public final class EchoSignal {
    public enum Verdict: Equatable, Sendable {
        /// The delayed Others Track explains the sound.
        case bleed
        /// The microphone carries sound the Others Track does not explain.
        case local
    }

    private static let frameDuration = SegmentSignal.levelFrameDuration
    private static let silent: Float = -100
    /// Lag search, in frames, of the microphone behind the Others Track: the acoustic path adds
    /// tens of milliseconds, the margins absorb the different start of the two captures.
    private static let lags = -15...30
    /// The bleed gain and the noise floor are estimated over this much audio on each side.
    private static let context: TimeInterval = 5
    /// Whether and how late the microphone hears the call: it changes only with the user's setup.
    private static let couplingContext: TimeInterval = 60
    /// Stretches whose centres share a block of this many frames (30 s) share one coupling
    /// estimate. Hex uses 10 s; 30 s costs a third, over a window of two minutes that barely moves.
    private static let couplingBlock = 1500
    /// The others speaking; digital silence is far below this.
    private static let othersActive: Float = -55
    private static let minOthersFrames = 25
    /// Frames this far above the microphone noise floor carry sound.
    private static let activeAboveFloor: Float = 6
    private static let gainPercentile: Float = 0.35
    /// Frames this far above the predicted bleed are local.
    private static let localMargin: Float = 9
    /// The room keeps the bleed audible after the frame that caused it, decaying.
    private static let reverbFrames = 8
    private static let reverbDecay: Float = 1.5
    /// Below this the microphone does not hear the call (headphones): every sound is local.
    private static let minCorrelation: Float = 0.2
    private static let minActiveFrames = 10
    private static let minGainFrames = 10
    /// Bleed when at most this share of the sound is local, local when at least this.
    private static let bleedMaxLocal: Float = 0.2
    private static let localMinLocal: Float = 0.5
    /// Half a second of local frames within one second is someone speaking in the room, even in a
    /// stretch that is mostly bleed; a keyboard click stays far below it.
    private static let burstWindow = 50
    private static let burstMinFrames = 25

    private let others: [Float]
    private let me: [Float]
    /// Correlation and lag per coupling block.
    private var couplings: [Int: (correlation: Float, lag: Int)?] = [:]

    /// `others` and `me` in dBFS, one per 20 ms from the start of the Meeting.
    public init(others: [Float], me: [Float]) {
        self.others = others
        self.me = me
    }

    /// Both Tracks from the levels of their Segments, each placed at its start; holes are silence.
    public convenience init(segments: [(segment: Segment, levels: [Float])]) {
        var tracks: [Track: [Float]] = [:]
        for (segment, levels) in segments {
            let first = Int((segment.start / Self.frameDuration).rounded())
            var track = tracks[segment.track] ?? []
            if track.count < first + levels.count {
                track += [Float](repeating: Self.silent, count: first + levels.count - track.count)
            }
            track.replaceSubrange(first..<(first + levels.count), with: levels)
            tracks[segment.track] = track
        }
        self.init(others: tracks[.others] ?? [], me: tracks[.me] ?? [])
    }

    /// What the Me Track between `start` and `end` (seconds from the start of the Meeting) is,
    /// `nil` when there is too little sound, or too little of the others, to tell.
    public func assess(from start: TimeInterval, to end: TimeInterval) -> Verdict? {
        guard let locality = locality(from: start, to: end) else { return nil }
        if locality.share >= Self.localMinLocal { return .local }
        if locality.share <= Self.bleedMaxLocal && locality.burst < Self.burstMinFrames { return .bleed }
        return nil
    }

    private func level(_ track: [Float], _ frame: Int) -> Float {
        track.indices.contains(frame) ? track[frame] : Self.silent
    }

    /// The best correlation and lag of the microphone behind the Others Track around `first..<last`.
    private func coupling(_ first: Int, _ last: Int) -> (correlation: Float, lag: Int)? {
        let block = (first + last) / 2 / Self.couplingBlock
        if let coupling = couplings[block] { return coupling }
        let center = block * Self.couplingBlock + Self.couplingBlock / 2
        let reach = Int(Self.couplingContext / Self.frameDuration)
        let lower = max(0, center - reach)
        let frames = lower..<max(lower, min(center + reach, me.count))
        let best = others.withUnsafeBufferPointer { others in
            me.withUnsafeBufferPointer { me in Self.bestLag(others: others, me: me, frames: frames) }
        }
        couplings[block] = best
        return best
    }

    /// The lag with the highest correlation between the two levels over `frames`, counting only
    /// the frames where the others speak. Plain loops on buffers: it runs for every block of a long
    /// Meeting, in Debug builds too.
    private static func bestLag(
        others: UnsafeBufferPointer<Float>, me: UnsafeBufferPointer<Float>, frames: Range<Int>
    ) -> (correlation: Float, lag: Int)? {
        var best: (correlation: Float, lag: Int)?
        for lag in lags {
            var count = 0
            var sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumYY = 0.0, sumXY = 0.0
            // Outside the Others Track the others are silent: those frames never count.
            let lower = max(frames.lowerBound, lag)
            for frame in lower..<max(lower, min(frames.upperBound, others.count + lag)) {
                let y = others[frame - lag]
                guard y > othersActive else { continue }
                let x = Double(me[frame]), yd = Double(y)
                count += 1
                sumX += x; sumY += yd; sumXX += x * x; sumYY += yd * yd; sumXY += x * yd
            }
            guard count >= minOthersFrames else { continue }
            let n = Double(count)
            let denominator = ((sumXX - sumX * sumX / n) * (sumYY - sumY * sumY / n)).squareRoot()
            let correlation = denominator <= .ulpOfOne ? 0 : Float((sumXY - sumX * sumY / n) / denominator)
            if best.map({ correlation > $0.correlation }) ?? true { best = (correlation, lag) }
        }
        return best
    }

    /// The share of the stretch's sound frames that are local and the most local frames within
    /// one second, `nil` when the stretch is nearly silent.
    private func locality(from start: TimeInterval, to end: TimeInterval) -> (share: Float, burst: Int)? {
        let first = max(0, Int(start / Self.frameDuration))
        let last = max(Int(end / Self.frameDuration), first + 1)
        let contextFrames = Int(Self.context / Self.frameDuration)
        let context = max(0, first - contextFrames)..<max(last, min(last + contextFrames, me.count))

        guard let floor = percentile(context.map { level(me, $0) }, 0.1) else { return nil }
        let active = (first..<last).filter { level(me, $0) >= floor + Self.activeAboveFloor }
        // Without the others nearby, or with a microphone that does not hear them, nothing explains the sound.
        guard let lag = coupling(first, last).flatMap({ $0.correlation >= Self.minCorrelation ? $0.lag : nil }) else {
            return active.count >= Self.minActiveFrames ? (1, min(active.count, Self.burstWindow)) : nil
        }

        func remote(_ frame: Int) -> Float {
            let source = frame - lag
            var loudest = level(others, source + 1) - Self.reverbDecay
            for reverb in 0...Self.reverbFrames {
                loudest = max(loudest, level(others, source - reverb) - Float(reverb) * Self.reverbDecay)
            }
            return max(loudest, Self.silent)
        }
        func gain(over span: Range<Int>, minFrames: Int) -> Float? {
            let loud = span.map { level(others, $0 - lag) }.filter { $0 > Self.othersActive }
            guard loud.count >= minFrames, let loudThreshold = percentile(loud, 0.5) else { return nil }
            // A low percentile, so my own voice over loud frames of the others does not inflate the bleed.
            return percentile(
                span.filter { level(others, $0 - lag) >= loudThreshold }.map { level(me, $0) - remote($0) },
                Self.gainPercentile
            )
        }
        // Estimated before and after the stretch, so a change of speaker volume on one side does
        // not drag down the bleed reference.
        let sides = [gain(over: context.lowerBound..<first, minFrames: Self.minGainFrames),
                     gain(over: last..<context.upperBound, minFrames: Self.minGainFrames)].compactMap { $0 }
        guard let gain = sides.max() ?? gain(over: context, minFrames: 1) else { return nil }

        let local = active.filter { level(me, $0) > max(gain + remote($0), floor) + Self.localMargin }
        if active.count < Self.minActiveFrames {
            let remoteFrames = (first..<last).filter { remote($0) > Self.othersActive }.count
            return local.isEmpty && remoteFrames * 2 >= last - first ? (0, 0) : nil
        }
        var burst = 0
        var from = 0
        for (to, frame) in local.enumerated() {
            while local[from] <= frame - Self.burstWindow { from += 1 }
            burst = max(burst, to + 1 - from)
        }
        return (Float(local.count) / Float(active.count), burst)
    }
}

private func percentile(_ values: [Float], _ fraction: Float) -> Float? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[Int((Float(sorted.count - 1) * fraction).rounded())]
}
