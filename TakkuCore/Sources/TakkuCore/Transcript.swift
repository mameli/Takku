import Foundation

/// A stretch of speech recognised in a Track. Times in seconds from the start of the Meeting.
public struct Utterance: Codable, Equatable, Sendable {
    public let track: Track
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    /// The Speaker of an Others Utterance, once told apart (see `assigningSpeakers`).
    public let speaker: Int?

    public init(track: Track, start: TimeInterval, end: TimeInterval, text: String, speaker: Int? = nil) {
        self.track = track
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

/// Consecutive Utterances of the same Track and Speaker, shown with a single timestamp.
public struct Paragraph: Equatable, Sendable {
    public let track: Track
    public let start: TimeInterval
    public let text: String
    public let speaker: Int?
    /// The name the user gave the Speaker in the Meeting note, if any.
    public let name: String?

    public init(track: Track, start: TimeInterval, text: String, speaker: Int? = nil, name: String? = nil) {
        self.track = track
        self.start = start
        self.text = text
        self.speaker = speaker
        self.name = speaker == nil ? nil : name
    }

    /// Who speaks, as the Transcript shows it: `Me`, `Speaker 2`, `Mario Rossi (Speaker 2)` once the
    /// user named them, or `Others` when not told apart. The number stays with the name, so the
    /// name can be changed later.
    public var label: String {
        guard track == .others, let speaker else { return track.label }
        return name.map { "\($0) (Speaker \(speaker))" } ?? "Speaker \(speaker)"
    }

    /// The user marked this paragraph as important while recording.
    public var isMarked: Bool {
        text.hasPrefix(Transcript.markSymbol)
    }

    func with(text: String? = nil, name: String?) -> Paragraph {
        Paragraph(track: track, start: start, text: text ?? self.text, speaker: speaker, name: name)
    }
}

/// The spoken text of a Meeting, with the two Tracks merged in time order.
public struct Transcript: Sendable {
    /// The copy of the Transcript in the Recording folder. It expires with the audio only when
    /// the Vault holds another copy; without one, retention must not delete the only Transcript.
    public static let recordingCopyFileName = "transcript.md"

    /// After a longer pause the same Track starts a new paragraph with a new timestamp.
    public static let paragraphBreak: TimeInterval = 30
    /// An Utterance starting later than this from the paragraph start opens a new one,
    /// so even a long monologue gets a timestamp about every minute.
    public static let maxParagraphDuration: TimeInterval = 60

    /// Starts the text of a paragraph a Mark falls in.
    public static let markSymbol = "⭐"

    public let paragraphs: [Paragraph]
    /// In time order. Only in the Transcript file: `markdown`, which the Summary reads, leaves them out.
    public let screenshots: [Screenshot]

    /// `vocabulary`: the variants it knows are replaced by their term in the text of the paragraphs.
    public init(utterances: [Utterance], vocabulary: Vocabulary = .empty) {
        var paragraphs: [Paragraph] = []
        var lastEnd: TimeInterval = 0
        let spoken = utterances.compactMap { utterance -> Utterance? in
            let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !Self.isAnnotation(text) else { return nil }
            return Utterance(
                track: utterance.track, start: utterance.start, end: utterance.end, text: text, speaker: utterance.speaker
            )
        }
        for utterance in spoken.sorted(by: { $0.start < $1.start }) {
            defer { lastEnd = utterance.end }
            if let last = paragraphs.last, last.track == utterance.track, last.speaker == utterance.speaker,
               utterance.start - lastEnd <= Self.paragraphBreak,
               utterance.start - last.start < Self.maxParagraphDuration {
                paragraphs[paragraphs.count - 1] = Paragraph(
                    track: last.track, start: last.start, text: last.text + " " + utterance.text, speaker: last.speaker
                )
            } else {
                paragraphs.append(Paragraph(
                    track: utterance.track, start: utterance.start, text: utterance.text, speaker: utterance.speaker
                ))
            }
        }
        let replaceVariants = vocabulary.variantReplacer()
        self.paragraphs = paragraphs.map {
            Paragraph(track: $0.track, start: $0.start, text: replaceVariants($0.text), speaker: $0.speaker)
        }
        screenshots = []
    }

    private init(paragraphs: [Paragraph], screenshots: [Screenshot]) {
        self.paragraphs = paragraphs
        self.screenshots = screenshots
    }

    /// The Speakers with the names the user gave them (by number); the others keep only the number.
    public func naming(_ names: [Int: String]) -> Transcript {
        Transcript(paragraphs: paragraphs.map { $0.with(name: $0.speaker.flatMap { names[$0] }) }, screenshots: screenshots)
    }

    /// The Transcript with these Screenshots, each under the paragraph it falls in (see `vaultFile`).
    public func withScreenshots(_ screenshots: [Screenshot]) -> Transcript {
        Transcript(paragraphs: paragraphs, screenshots: screenshots.sorted(by: Screenshot.inTimeOrder))
    }

    /// The paragraphs the Marks fall in, starred: for each Mark the last paragraph starting at or
    /// before it, of either Track (a Mark usually comes right after what mattered). A Mark before
    /// any speech stars nothing; several in one paragraph give one star.
    public func marking(_ marks: [TimeInterval]) -> Transcript {
        let marked = Set(marks.compactMap { mark in paragraphs.lastIndex { $0.start <= mark } })
        return Transcript(paragraphs: paragraphs.enumerated().map { index, paragraph in
            guard marked.contains(index), !paragraph.isMarked else { return paragraph }
            return paragraph.with(text: "\(Self.markSymbol) \(paragraph.text)", name: paragraph.name)
        }, screenshots: screenshots)
    }

    /// Whether some Speaker has a name given by the user.
    public var hasNamedSpeakers: Bool {
        paragraphs.contains { $0.name != nil }
    }

    /// Body of the Transcript file: `**[mm:ss] Me:** text`, one paragraph per block.
    public var markdown: String {
        Self.markdown(of: paragraphs)
    }

    static func markdown(of paragraphs: [Paragraph]) -> String {
        paragraphs
            .map { "**[\(elapsedLabel($0.start))] \($0.label):** \($0.text)\n" }
            .joined(separator: "\n")
    }

    /// The Transcript file body: the paragraphs with each Screenshot on its own line under the one it
    /// falls in (the last starting at or before it, like a Mark); those before any speech come first.
    private var markdownWithScreenshots: String {
        var blocks: [String] = []
        var pending = screenshots[...]
        func embedScreenshots(until end: TimeInterval) {
            while let next = pending.first, next.time < end {
                blocks.append("![[\(next.embed)]]\n")
                pending = pending.dropFirst()
            }
        }
        for (index, paragraph) in paragraphs.enumerated() {
            if index == 0 { embedScreenshots(until: paragraph.start) }
            blocks.append(Self.markdown(of: [paragraph]))
            embedScreenshots(until: paragraphs.indices.contains(index + 1) ? paragraphs[index + 1].start : .infinity)
        }
        embedScreenshots(until: .infinity)
        return blocks.joined(separator: "\n")
    }

    /// Reads back the Transcript file written in the Vault (even if edited by hand): lines
    /// that do not start with `**[time] Me/Speaker N/Others:**` stay in the paragraph they are in,
    /// except the image embeds, which are Screenshots and never text the model reads.
    public static func parse(vaultFile: String) -> (transcript: Transcript, language: String?) {
        let markdown = MarkdownLines(vaultFile)
        let language = markdown.value("language")

        var paragraphs: [Paragraph] = []
        var screenshots: [Screenshot] = []
        for line in markdown.lines[markdown.bodyStart...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let header = Header(trimmed) {
                paragraphs.append(header.paragraph)
            } else if let screenshot = Screenshot.embedded(in: trimmed, fallbackTime: paragraphs.last?.start ?? 0) {
                screenshots.append(screenshot)
            } else if !trimmed.isEmpty, let last = paragraphs.popLast() {
                paragraphs.append(last.with(text: last.text + " " + trimmed, name: last.name))
            }
        }
        return (Transcript(paragraphs: paragraphs, screenshots: screenshots), language)
    }

    /// The Transcript file in the Vault with the Speakers' labels changed to the names the user
    /// gives them now; everything else, text included, stays as it is. `nil` if no label changes.
    public static func relabeling(vaultFile: String, names: [Int: String]) -> String? {
        var markdown = MarkdownLines(vaultFile)
        var changed = false
        for index in markdown.lines.indices.dropFirst(markdown.bodyStart) {
            guard let header = Header(markdown.lines[index].trimmingCharacters(in: .whitespaces)) else { continue }
            let before = header.paragraph
            let after = before.with(name: before.speaker.flatMap { names[$0] })
            guard after.label != before.label else { continue }
            markdown.lines[index] = "**[\(header.time)] \(after.label):** \(after.text)"
            changed = true
        }
        return changed ? markdown.text : nil
    }

    /// The first line of a paragraph in the Transcript file: `**[12:34] Speaker 2:** text`.
    private struct Header {
        let time: Substring
        let paragraph: Paragraph

        init?(_ line: String) {
            let pattern = /^\*\*\[(\d+(?::\d{2}){1,2})\] (Me|Others|Speaker (\d+)|(.+?) \(Speaker (\d+)\)):\*\* ?(.*)$/
            guard let match = line.wholeMatch(of: pattern) else { return nil }
            time = match.1
            let seconds = match.1.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
            paragraph = Paragraph(
                track: match.2 == "Me" ? .me : .others, start: seconds, text: String(match.6),
                speaker: (match.3 ?? match.5).flatMap { Int($0) }, name: match.4.map(String.init)
            )
        }
    }

    /// The Transcript file in the Vault: frontmatter linking back to the Meeting note.
    /// `language` is `nil` if no speech was heard in the Meeting.
    public func vaultFile(takkuID: UUID, meetingNoteName: String, language: String?) -> String {
        var frontmatter = ["---", "takku_id: \(takkuID.uuidString)", "meeting: \(MeetingNote.wikiLink(meetingNoteName))"]
        if let language { frontmatter.append("language: \(language)") }
        frontmatter.append("---")
        return frontmatter.joined(separator: "\n") + "\n" + markdownWithScreenshots
    }

    /// Whisper describes non-speech in brackets (`[BLANK_AUDIO]`, `[Music]`)
    /// and on silence it makes up whole sentences in parentheses.
    private static func isAnnotation(_ text: String) -> Bool {
        (text.hasPrefix("[") && text.hasSuffix("]")) || (text.hasPrefix("(") && text.hasSuffix(")"))
    }
}
