import Foundation

/// The Meetings in the notes folder as an agent sees them through `takku mcp`: every Meeting note
/// and Transcript under `Meetings/`, wherever the user moved them inside it, told apart by their
/// frontmatter (a Transcript links its note with `meeting:`). Read only: it never writes.
public struct MeetingLibrary: Sendable {
    public struct Meeting: Equatable, Sendable {
        public let id: UUID
        /// The note's name without the date Takku puts before it.
        public let title: String
        /// When it started, from the frontmatter `date` (`yyyy-MM-ddTHH:mm`, local time).
        public let date: String?
        public let duration: String?
        public let language: String?
        public let template: String?
        public let participants: [String]
        /// Names the user gave the Speakers, as `Speaker N = Name`.
        public let speakers: [String]
        /// The folder of the note relative to `Meetings/`, empty when it is there.
        public let folder: String
        public let note: URL
        public let transcript: URL?
    }

    /// A Meeting the search found, with the lines that matched.
    public struct Match: Equatable, Sendable {
        public let meeting: Meeting
        public let lines: [String]
        public let occurrences: Int
    }

    public let meetingsFolder: URL

    /// `notesFolder`: the folder chosen in Settings; the Meetings are in its `Meetings` folder.
    public init(notesFolder: URL) {
        meetingsFolder = notesFolder.appending(path: "Meetings", directoryHint: .isDirectory)
    }

    /// Every Meeting with a note, newest first. A Transcript without a note is left out; of Sync
    /// copies with the same `takku_id`, the first found counts.
    public func meetings() -> [Meeting] {
        var notes: [UUID: (URL, MarkdownLines)] = [:]
        var transcripts: [UUID: URL] = [:]
        let files = FileManager.default.enumerator(at: meetingsFolder, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "md", let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let markdown = MarkdownLines(content)
            guard let id = markdown.value(MeetingNote.TakkuKey.takkuID.rawValue).flatMap(UUID.init(uuidString:)) else { continue }
            if markdown.value("meeting") != nil {
                if transcripts[id] == nil { transcripts[id] = url }
            } else if notes[id] == nil {
                notes[id] = (url, markdown)
            }
        }
        let rootComponents = meetingsFolder.standardizedFileURL.pathComponents
        return notes.map { id, entry in
            let (url, markdown) = entry
            let folder = url.deletingLastPathComponent().standardizedFileURL.pathComponents.dropFirst(rootComponents.count)
            return Meeting(
                id: id,
                title: Self.title(fromNoteName: url.deletingPathExtension().lastPathComponent),
                date: markdown.value("date"),
                duration: markdown.value(MeetingNote.TakkuKey.duration.rawValue),
                language: markdown.value(MeetingNote.TakkuKey.language.rawValue),
                template: markdown.value(MeetingNote.TakkuKey.template.rawValue),
                participants: markdown.list("participants") ?? [],
                speakers: markdown.list("speakers") ?? [],
                folder: folder.joined(separator: "/"),
                note: url,
                transcript: transcripts[id]
            )
        }
        .sorted { ($0.date ?? "", $0.title) > ($1.date ?? "", $1.title) }
    }

    /// The Meetings from `from` to `to` (`yyyy-MM-dd`, both included) whose title, folder,
    /// participants or speakers contain `query`, ignoring case and accents; `nil` skips a filter.
    public func meetings(from: String?, to: String?, matching query: String?) -> [Meeting] {
        let query = query.map(Self.folded)
        return meetings().filter { meeting in
            let day = meeting.date.map { String($0.prefix(10)) } ?? ""
            if let from, day < from { return false }
            if let to, day > to { return false }
            guard let query else { return true }
            return Self.folded(([meeting.title, meeting.folder] + meeting.participants + meeting.speakers).joined(separator: "\n"))
                .contains(query)
        }
    }

    /// The Meeting with this id, `nil` when there is none.
    public func meeting(id: UUID) -> Meeting? {
        meetings().first { $0.id == id }
    }

    /// The Meetings whose note or Transcript contains every word of `query`, ignoring case and
    /// accents, most occurrences first; for each, up to `linesPerMeeting` lines with a word.
    public func search(_ query: String, linesPerMeeting: Int = 5) -> [Match] {
        let terms = Self.folded(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        return meetings().compactMap { meeting -> Match? in
            let texts = [meeting.note, meeting.transcript].compactMap { $0 }
                .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            let lines = texts.flatMap { text in
                let markdown = MarkdownLines(text)
                return markdown.lines.dropFirst(markdown.bodyStart)
            }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let folded = lines.map(Self.folded)
            let whole = ([Self.folded(meeting.title)] + folded).joined(separator: "\n")
            guard terms.allSatisfy(whole.contains) else { return nil }
            var occurrences = 0
            var matching: [String] = []
            for (line, foldedLine) in zip(lines, folded) {
                let count = terms.reduce(0) { $0 + foldedLine.components(separatedBy: $1).count - 1 }
                guard count > 0 else { continue }
                occurrences += count
                if matching.count < linesPerMeeting { matching.append(line.trimmingCharacters(in: .whitespaces)) }
            }
            return Match(meeting: meeting, lines: matching, occurrences: occurrences)
        }
        .sorted { ($0.occurrences, $0.meeting.date ?? "") > ($1.occurrences, $1.meeting.date ?? "") }
    }

    /// "2026-11-01 1658 - Configurazione call di prova" → "Configurazione call di prova".
    static func title(fromNoteName name: String) -> String {
        guard let match = name.wholeMatch(of: /\d{4}-\d{2}-\d{2} \d{4} - (.+)/) else { return name }
        return String(match.1)
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

extension MeetingLibrary.Meeting {
    /// Its metadata as JSON fields, the same for `takku mcp` and `takku list --json`.
    var fields: [String: Any] {
        var fields: [String: Any] = [
            "id": id.uuidString, "title": title, "folder": folder, "has_transcript": transcript != nil,
        ]
        fields["date"] = date
        fields["duration"] = duration
        fields["language"] = language
        if !participants.isEmpty { fields["participants"] = participants }
        if !speakers.isEmpty { fields["speakers"] = speakers }
        return fields
    }

    /// Its Meeting note and, with `includeTranscript`, its Transcript, each under its path.
    func text(includeTranscript: Bool) -> String {
        var parts = ["# \(title)", "Meeting note (\(note.path(percentEncoded: false))):",
                     (try? String(contentsOf: note, encoding: .utf8)) ?? "(unreadable)"]
        if includeTranscript {
            if let transcript {
                parts += ["Transcript (\(transcript.path(percentEncoded: false))):",
                          (try? String(contentsOf: transcript, encoding: .utf8)) ?? "(unreadable)"]
            } else {
                parts.append("No Transcript in the notes folder.")
            }
        }
        return parts.joined(separator: "\n\n")
    }
}
