import Foundation

/// Me sentences closer than this belong to the same run, compared as a whole: Whisper splits
/// the leaked echo into fragments too short to judge one by one.
private let maxPauseInRun: TimeInterval = 2
/// Echo arrives at once, but Whisper's timestamps inside a speech range drift by a few seconds.
private let timeTolerance: TimeInterval = 5
/// Shorter runs ("ok", "sì") are kept: the same word at the same moment can be a real reply.
private let minWords = 3
private let minSharedFraction = 0.8

/// Removes from the Me Track the others' voice leaked into the microphone (speakers without
/// headphones: Takku has no echo cancellation). A run of Me Utterances is echo when `signal` says
/// the delayed Others Track explains its sound (bleed); it is kept when the signal shows someone
/// speaking in the room (local), even if the words match, since I may talk over the others. When
/// the signal cannot tell, or there is none, it is echo if almost all its words appear, in the
/// same order, in what the others say at the same moment. In a run that is echo, a sentence the
/// signal shows local survives; in one that is not, each sentence is judged on its own.
public func removingEcho(_ utterances: [Utterance], signal: EchoSignal? = nil) -> [Utterance] {
    let others = utterances.filter { $0.track == .others }.sorted { $0.start < $1.start }
    let me = utterances.indices.filter { utterances[$0].track == .me }.sorted { utterances[$0].start < utterances[$1].start }

    var runs: [[Int]] = []
    for index in me {
        if let last = runs.last?.last, utterances[index].start - utterances[last].end <= maxPauseInRun {
            runs[runs.count - 1].append(index)
        } else {
            runs.append([index])
        }
    }

    func verdict(_ run: [Int]) -> EchoSignal.Verdict? {
        signal?.assess(from: utterances[run.first!].start, to: run.map { utterances[$0].end }.max()!)
    }
    func repeatsOthers(_ run: [Int]) -> Bool {
        let meWords = run.flatMap { words(utterances[$0].text) }
        guard meWords.count >= minWords else { return false }
        let from = utterances[run.first!].start - timeTolerance
        let to = utterances[run.last!].end + timeTolerance
        let othersWords = others.filter { $0.end >= from && $0.start <= to }.flatMap { words($0.text) }
        return Double(commonSubsequenceLength(meWords, othersWords)) >= minSharedFraction * Double(meWords.count)
    }
    func isEcho(_ run: [Int]) -> Bool {
        switch verdict(run) {
        case .bleed: true
        case .local: false
        case nil: repeatsOthers(run)
        }
    }

    var echo = Set<Int>()
    for run in runs {
        if isEcho(run) {
            // Bleed can run straight into my own sentence: one the signal shows local stays.
            echo.formUnion(run.filter { words(utterances[$0].text).count < minWords || verdict([$0]) != .local })
        } else if run.count > 1, signal != nil {
            echo.formUnion(run.filter { isEcho([$0]) })
        }
    }
    return utterances.indices.filter { !echo.contains($0) }.map { utterances[$0] }
}

/// My voice into my microphone peaks between -10 and -25 dBFS; what echo cancellation leaves of
/// the others' voice peaks around -40, loud enough for the speech ranges and turned into random
/// words ("The five.", "Oh yeah") in any language. Measured on 13 real Meetings: 25 dB below the
/// loudest Me sentence removes that residue and keeps the faintest real replies by over 10 dB.
/// Takku used echo cancellation up to 1.5.1: a Retry of an older Recording still finds residue.
private let maxBelowLoudest = 25.0

/// Removes Me Utterances fainter than the loudest Me one by more than 25 dB: the others' voice
/// left in the microphone by echo cancellation, too garbled for `removingEcho` to match their
/// words. The reference is the loudest one, not a typical one, because in a Meeting where I
/// barely speak most Me Utterances are residue. A `nil` level (not measured) keeps the Utterance.
public func removingEchoResidue(_ measured: [(utterance: Utterance, level: Double?)]) -> [Utterance] {
    let loudest = measured.filter { $0.utterance.track == .me }.compactMap(\.level).max()
    return measured.filter { item in
        guard item.utterance.track == .me, let loudest, let level = item.level else { return true }
        return level >= loudest - maxBelowLoudest
    }.map(\.utterance)
}

/// The loudness of a stretch of audio: the RMS of its loudest 100 ms (windows every 50 ms),
/// in dBFS. A stretch shorter than 100 ms is one window.
public func peakLevel(of samples: ArraySlice<Float>, sampleRate: Double) -> Double {
    let window = Int(0.1 * sampleRate)
    let hop = window / 2
    var loudest: Float = 0
    var start = samples.startIndex
    repeat {
        let slice = samples[start..<min(samples.endIndex, start + window)]
        if !slice.isEmpty {
            loudest = max(loudest, slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count))
        }
        start += hop
    } while start + window <= samples.endIndex
    return 10 * log10(Double(loudest) + 1e-12)
}

private func words(_ text: String) -> [String] {
    text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
}

/// The echo reaches the microphone degraded and the recognizer may spell it differently: words of
/// at least 4 letters match when at least 60% of their letters agree ("riunione" and "riunioni").
/// Loose on its own, it only counts inside a run whose words almost all match in order.
private func sameWord(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    let a = Array(a), b = Array(b)
    guard a.count >= 4, b.count >= 4 else { return false }
    return 1 - Double(editDistance(a, b)) / Double(max(a.count, b.count)) >= 0.6
}

private func editDistance(_ a: [Character], _ b: [Character]) -> Int {
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for (row, charA) in a.enumerated() {
        current[0] = row + 1
        for (column, charB) in b.enumerated() {
            current[column + 1] = min(previous[column] + (charA == charB ? 0 : 1), previous[column + 1] + 1, current[column] + 1)
        }
        swap(&previous, &current)
    }
    return previous[b.count]
}

/// Length of the longest sequence of words found in both, in the same order.
private func commonSubsequenceLength(_ a: [String], _ b: [String]) -> Int {
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    var previous = [Int](repeating: 0, count: b.count + 1)
    for wordA in a {
        var current = [Int](repeating: 0, count: b.count + 1)
        for (j, wordB) in b.enumerated() {
            current[j + 1] = sameWord(wordA, wordB) ? previous[j] + 1 : max(previous[j + 1], current[j])
        }
        previous = current
    }
    return previous[b.count]
}
