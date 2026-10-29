import Foundation

/// A stretch of a Speaker's voice to play while naming Speakers: one of their paragraphs in the
/// Transcript, cut where someone else starts speaking, with the first words of what they say there
/// to recognise them without listening (the only help once the audio is deleted).
public struct SpeakerSample: Equatable, Sendable {
    public let speaker: Int
    /// Seconds from the start of the Meeting.
    public let start: TimeInterval
    public let duration: TimeInterval
    public let quote: String

    /// Long enough to recognise a voice, short enough to hear several Speakers in a row.
    public static let maxDuration: TimeInterval = 8
    /// The Transcript times are whole seconds: a paragraph followed in the same second still plays.
    public static let minDuration: TimeInterval = 2
    static let quoteWords = 12

    public init(speaker: Int, start: TimeInterval, duration: TimeInterval, quote: String) {
        self.speaker = speaker
        self.start = start
        self.duration = duration
        self.quote = quote
    }

    /// Up to `limit` samples for every Speaker of the Others Track, their longest paragraphs first:
    /// a long paragraph is more likely clear speech than a short "ok" said over someone else.
    public static func samples(in transcript: Transcript, limit: Int = 3) -> [Int: [SpeakerSample]] {
        let paragraphs = transcript.paragraphs
        var bySpeaker: [Int: [(length: Int, sample: SpeakerSample)]] = [:]
        for (index, paragraph) in paragraphs.enumerated() {
            guard paragraph.track == .others, let speaker = paragraph.speaker else { continue }
            // A paragraph runs until someone else's begins: consecutive ones of the same voice are
            // only split by a pause or by length.
            let next = paragraphs[(index + 1)...].first { $0.track != paragraph.track || $0.speaker != speaker }
            let available = next.map { $0.start - paragraph.start } ?? maxDuration
            let text = paragraph.isMarked
                ? String(paragraph.text.dropFirst(Transcript.markSymbol.count)).trimmingCharacters(in: .whitespaces)
                : paragraph.text
            let sample = SpeakerSample(
                speaker: speaker, start: paragraph.start,
                duration: min(max(available, minDuration), maxDuration), quote: quote(text)
            )
            bySpeaker[speaker, default: []].append((text.count, sample))
        }
        return bySpeaker.mapValues { candidates in
            Array(candidates.enumerated()
                .sorted { ($0.element.length, -$0.offset) > ($1.element.length, -$1.offset) }
                .prefix(limit)
                .map(\.element.sample))
        }
    }

    private static func quote(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        let kept = words.prefix(quoteWords).joined(separator: " ")
        return words.count > quoteWords ? kept + "…" : kept
    }
}

extension Recording {
    /// The Segment of `track` holding a Meeting time, and where in its file that time is.
    /// `nil` before the Track's first Segment.
    public func segment(of track: Track, at time: TimeInterval) -> (segment: Segment, offset: TimeInterval)? {
        segments
            .filter { $0.track == track && $0.start <= time }
            .max { $0.start < $1.start }
            .map { ($0, time - $0.start) }
    }
}
