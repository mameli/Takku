import Foundation

/// A stretch in which one voice of the Others Track speaks, as diarization heard it. `voice` is
/// the diarizer's own id; times in seconds from the start of the Meeting.
public struct SpeakerTurn: Equatable, Codable, Sendable {
    public let voice: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(voice: String, start: TimeInterval, end: TimeInterval) {
        self.voice = voice
        self.start = start
        self.end = end
    }
}

/// A short reply ("ok", "sì") is often too short for diarization to count as speech: it takes the
/// voice of a turn this close, otherwise it stays without a Speaker.
private let nearestTurnTolerance: TimeInterval = 2

/// Gives each Others Utterance the Speaker whose turns cover most of it. Speakers are numbered
/// 1, 2, … in the order they first speak in the Transcript, so a voice that never matches an
/// Utterance (noise, a cough) uses up no number. Me Utterances are left alone.
public func assigningSpeakers(to utterances: [Utterance], turns: [SpeakerTurn]) -> [Utterance] {
    let voices = utterances.map { $0.track == .others ? voice(of: $0, in: turns) : nil }
    var numbers: [String: Int] = [:]
    for index in utterances.indices.sorted(by: { utterances[$0].start < utterances[$1].start }) {
        if let voice = voices[index], numbers[voice] == nil { numbers[voice] = numbers.count + 1 }
    }
    return zip(utterances, voices).map { utterance, voice in
        Utterance(
            track: utterance.track, start: utterance.start, end: utterance.end, text: utterance.text,
            speaker: voice.flatMap { numbers[$0] }
        )
    }
}

private func voice(of utterance: Utterance, in turns: [SpeakerTurn]) -> String? {
    var overlap: [String: TimeInterval] = [:]
    for turn in turns {
        let shared = min(utterance.end, turn.end) - max(utterance.start, turn.start)
        if shared > 0 { overlap[turn.voice, default: 0] += shared }
    }
    if let longest = overlap.max(by: { $0.value < $1.value }) { return longest.key }

    func distance(_ turn: SpeakerTurn) -> TimeInterval {
        max(turn.start - utterance.end, utterance.start - turn.end)
    }
    return turns
        .filter { distance($0) <= nearestTurnTolerance }
        .min { distance($0) < distance($1) }?
        .voice
}
