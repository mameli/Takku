import Foundation

/// The file in the Vault with the frontmatter, the Managed section and the personal notes of a Meeting.
///
/// Takku only rewrites the Managed section and its own frontmatter keys: everything else
/// belongs to the user.
public struct MeetingNote: Equatable, Sendable {
    /// The frontmatter keys that belong to Takku. `date` and `tags` are written only at
    /// creation and belong to the user afterwards, so they are not listed here.
    public enum TakkuKey: String, Sendable, CaseIterable {
        case takkuID = "takku_id"
        case duration
        case language
        case summaryProvider = "summary_provider"
        case template
        case transcript
    }

    /// How the Summary of a Meeting went.
    public enum SummaryOutcome: Equatable, Sendable {
        case written(text: String, template: String, provider: String)
        /// No Summary Profile chosen: the note holds only the Transcript link.
        case transcriptOnly
        case failed(reason: String)
    }

    public static let managedStart = "%% takku:start %%"
    public static let managedEnd = "%% takku:end %%"
    public static let personalNotesHeading = "## Personal notes"
    static let screenshotsHeading = "### Screenshots"

    private enum Marker {
        case start, end

        init?(_ line: String) {
            switch line.trimmingCharacters(in: .whitespaces) {
            case MeetingNote.managedStart: self = .start
            case MeetingNote.managedEnd: self = .end
            default: return nil
            }
        }
    }

    public private(set) var content: String

    /// The content is normalised: no BOM, `\n` line endings.
    public init(content: String) {
        self.content = MarkdownLines(content).text
    }

    /// `participants`: the invited participants of the calendar event, if there is one. Like `date`
    /// and `tags` they are written only here and belong to the user afterwards.
    public static func initial(
        takkuID: UUID, startedAt: Date, participants: [String] = [], timeZone: TimeZone = .current,
        isImport: Bool = false, personalNotes: String? = nil
    ) -> MeetingNote {
        // `takku import --notes`: what the user tells the Summary about the file, as if typed in the
        // note. A Managed section marker in it would split the note. It can be a video's description, so it
        // is read as lines the way the note is, and goes through the same defusing as the model's reply.
        let notes = MarkdownLines(personalNotes ?? "").lines.filter { Marker($0) == nil }.map(Self.defused)
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let participantsEntry = participantsLines(participants).map { "\n" + $0 }.joined()
        let status = isImport
            ? "⏳ Imported recording queued for Processing."
            : "⏺ Recording in progress: the summary will appear here after you stop."
        return MeetingNote(content: """
            ---
            takku_id: \(takkuID.uuidString)
            date: \(DateFormatter.posix("yyyy-MM-dd'T'HH:mm", timeZone: timeZone).string(from: startedAt))
            tags: [meeting]\(participantsEntry)
            ---
            \(managedStart)
            \(status)
            \(managedEnd)

            \(personalNotesHeading)
            \(notes.isEmpty ? "" : notes + "\n")

            """)
    }

    /// The frontmatter `takku_id`, `nil` if missing (the same text in the body does not count).
    public var takkuID: UUID? {
        let markdown = MarkdownLines(content)
        return markdown.value(TakkuKey.takkuID.rawValue).flatMap(UUID.init(uuidString:))
    }

    /// The Transcript file named by Takku's frontmatter link, without its extension. Used to
    /// disambiguate Sync copies that have the same `takku_id`.
    public var transcriptName: String? {
        guard let link = MarkdownLines(content).value(TakkuKey.transcript.rawValue),
              link.prefix(2) == "[[", link.suffix(2) == "]]"
        else { return nil }
        let target = link.dropFirst(2).dropLast(2).split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
        let name = target.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }

    /// The names the user gave the Speakers, from the frontmatter list `speakers`
    /// (`- Speaker 1 = Mario Rossi`). Entries in another form are ignored; for a number given
    /// twice, the first one counts.
    public var speakerNames: [Int: String] {
        var names: [Int: String] = [:]
        for entry in MarkdownLines(content).list("speakers") ?? [] {
            guard let match = entry.wholeMatch(of: /[Ss]peaker\s+(\d+)\s*=\s*(.*\S)\s*/),
                  let number = Int(match.1), names[number] == nil
            else { continue }
            names[number] = String(match.2)
        }
        return names
    }

    /// The invited participants written at the start from the calendar, as the user left them.
    public var participants: [String] {
        MarkdownLines(content).list("participants") ?? []
    }

    /// Replaces `participants` with those of another calendar event, chosen by the user while
    /// recording; none removes the key. Where the key was, otherwise at the end of the frontmatter.
    public mutating func replaceParticipants(with participants: [String]) {
        var markdown = MarkdownLines(content)
        let entry = Self.participantsLines(participants)
        if let entryLines = Self.entryLines("participants", in: markdown) {
            markdown.lines.replaceSubrange(entryLines, with: entry)
        } else if !entry.isEmpty {
            if markdown.frontmatterClose == nil { markdown.lines.insert(contentsOf: ["---", "---"], at: 0) }
            markdown.lines.insert(contentsOf: entry, at: markdown.frontmatterClose!)
        }
        content = markdown.text
    }

    /// Replaces the user-owned `speakers` list. Empty names are omitted and the list stays sorted
    /// by Speaker number; every other frontmatter key and the body stay untouched.
    public mutating func replaceSpeakerNames(with names: [Int: String]) {
        var markdown = MarkdownLines(content)
        let cleaned = names.compactMap { number, name -> (Int, String)? in
            let name = CalendarEvent.oneLine(name)
            return name.isEmpty ? nil : (number, name)
        }
        .sorted { $0.0 < $1.0 }
        let entry = cleaned.isEmpty ? [] : ["speakers:"] + cleaned.map { "  - Speaker \($0.0) = \($0.1)" }
        if let entryLines = Self.entryLines("speakers", in: markdown) {
            markdown.lines.replaceSubrange(entryLines, with: entry)
        } else if !entry.isEmpty {
            if markdown.frontmatterClose == nil { markdown.lines.insert(contentsOf: ["---", "---"], at: 0) }
            markdown.lines.insert(contentsOf: entry, at: markdown.frontmatterClose!)
        }
        content = markdown.text
    }

    /// Replaces the text between the Managed section markers with `body`.
    ///
    /// If the user deleted one or both markers, the leftover ones are removed and the managed
    /// section is recreated at the top of the body, without deleting any other text. Markers
    /// inside code blocks do not count.
    public mutating func replaceManagedSection(with body: String) {
        var markdown = MarkdownLines(content)
        // A marker inside the text (e.g. in the model's reply) would close the Managed section next time.
        // Lines as the note is read back: `\r` is a line break there too, so a marker after one counts.
        var bodyLines = MarkdownLines(body).lines.filter { Marker($0) == nil }.map(Self.defused)
        // A code block the reply leaves open would hide the end marker and put the rest of the note outside.
        if let open = Self.openFence(in: bodyLines) { bodyLines.append(open) }
        let section = [Self.managedStart] + bodyLines + [Self.managedEnd]

        if let managed = Self.managedRange(in: markdown) {
            markdown.lines.replaceSubrange(managed, with: section)
        } else {
            for index in Self.markerLines(in: markdown).map(\.index).reversed() {
                markdown.lines.remove(at: index)
            }
            markdown.lines.insert(contentsOf: section + [""], at: markdown.bodyStart)
        }
        content = markdown.text
    }

    /// The whole body outside the Managed section, without the Personal notes heading and
    /// without double blank lines. Empty if the user wrote nothing.
    public var personalNotes: String {
        var markdown = MarkdownLines(content)
        if let managed = Self.managedRange(in: markdown) {
            markdown.lines.removeSubrange(managed)
        }
        var lines = Array(markdown.lines.dropFirst(markdown.bodyStart))
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces) == Self.personalNotesHeading }

        var kept: [String] = []
        for line in lines {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            let previousIsBlank = kept.last?.isEmpty ?? true
            if isBlank && previousIsBlank { continue }
            kept.append(isBlank ? "" : line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Summary as the Managed section holds it, without the Transcript link: `nil` when no
    /// Summary was written (recording or import placeholder, an error, *Transcript* as Profile).
    public var summary: String? {
        let markdown = MarkdownLines(content)
        guard let managed = Self.managedRange(in: markdown) else { return nil }
        var lines = Array(markdown.lines[(managed.lowerBound + 1)..<managed.upperBound])
        if let link = lines.lastIndex(where: { $0.hasPrefix("Full transcript: [[") }) { lines.remove(at: link) }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // With *Transcript* as Profile the section can still hold the Screenshots, and nothing else.
        guard !body.isEmpty, !["⚠️", "⏺", "⏳", Self.screenshotsHeading].contains(where: { body.hasPrefix($0) }) else {
            return nil
        }
        return body
    }

    /// Whether the Managed section holds a completed Summary or Transcript, rather than the
    /// recording or import placeholder, an error or no result. A failed Retry must leave that result intact.
    public var hasSuccessfulOutcome: Bool {
        let markdown = MarkdownLines(content)
        guard let managed = Self.managedRange(in: markdown) else { return false }
        let body = markdown.lines[(managed.lowerBound + 1)..<managed.upperBound]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !body.isEmpty && !["⚠️", "⏺", "⏳"].contains { body.hasPrefix($0) }
    }

    /// Records the outcome of Processing: Takku's frontmatter keys (restoring `takku_id` if the
    /// user deleted it), the Summary or the failure reason, the Screenshots and the Transcript link
    /// in the managed section.
    public mutating func recordProcessing(
        takkuID: UUID, duration: TimeInterval, language: String?, transcriptName: String,
        summary: SummaryOutcome, screenshots: [Screenshot] = []
    ) {
        if case .failed = summary, hasSuccessfulOutcome { return }
        var values: [(key: TakkuKey, value: String)] = [
            (.takkuID, takkuID.uuidString),
            (.duration, Self.durationValue(duration)),
            (.transcript, Self.wikiLink(transcriptName)),
        ]
        if let language { values.append((.language, language)) }
        setFrontmatter(values)
        recordSummary(takkuID: takkuID, transcriptName: transcriptName, summary: summary, screenshots: screenshots)
    }

    /// Records a new Summary of a Meeting already processed: Summary, Template and provider
    /// change, while duration, language and Transcript stay those of the Processing.
    public mutating func recordRegeneration(
        takkuID: UUID, transcriptName: String, summary: SummaryOutcome, screenshots: [Screenshot] = []
    ) {
        recordSummary(takkuID: takkuID, transcriptName: transcriptName, summary: summary, screenshots: screenshots)
    }

    /// Records a failed Processing: the reason appears in the Managed section. A Meeting that
    /// already had a successful outcome keeps it; the failure remains visible in the app.
    public mutating func recordFailure(takkuID: UUID, reason: String) {
        guard !hasSuccessfulOutcome else { return }
        setFrontmatter([(.takkuID, takkuID.uuidString)])
        replaceManagedSection(with: "⚠️ \(reason)")
    }

    /// Obsidian link as a YAML value (quoted, otherwise `[[` would be a list).
    public static func wikiLink(_ name: String) -> String {
        "\"[[\(name)]]\""
    }

    /// Sets the given keys (values already in YAML): replaces existing ones, including any
    /// continuation lines, and appends missing ones at the end. Other keys stay.
    public mutating func setFrontmatter(_ values: [(key: TakkuKey, value: String)]) {
        var markdown = MarkdownLines(content)
        if markdown.frontmatterClose == nil {
            markdown.lines.insert(contentsOf: ["---", "---"], at: 0)
        }
        for (key, value) in values {
            let entry = "\(key.rawValue): \(value)"
            guard let entryLines = Self.entryLines(key, in: markdown) else {
                markdown.lines.insert(entry, at: markdown.frontmatterClose!)
                continue
            }
            markdown.lines.replaceSubrange(entryLines, with: [entry])
        }
        content = markdown.text
    }

    // MARK: - Private

    private mutating func removeFrontmatter(_ keys: [TakkuKey]) {
        var markdown = MarkdownLines(content)
        for key in keys {
            if let entryLines = Self.entryLines(key, in: markdown) { markdown.lines.removeSubrange(entryLines) }
        }
        content = markdown.text
    }

    /// The `participants` entry as YAML lines, quoted; none without participants.
    private static func participantsLines(_ participants: [String]) -> [String] {
        participants.isEmpty ? [] : ["participants:"] + participants.map {
            "  - \"\(CalendarEvent.oneLine($0).replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
    }

    private static func entryLines(_ key: TakkuKey, in markdown: MarkdownLines) -> Range<Int>? {
        entryLines(key.rawValue, in: markdown)
    }

    /// The lines of a frontmatter entry, including the indented lines of a multi-line value.
    private static func entryLines(_ key: String, in markdown: MarkdownLines) -> Range<Int>? {
        guard let close = markdown.frontmatterClose,
              let line = markdown.lines[1..<close].firstIndex(where: { $0.hasPrefix("\(key):") })
        else { return nil }
        var next = line + 1
        while next < close, markdown.lines[next].first.map({ $0 == " " || $0 == "\t" || $0 == "-" }) == true {
            next += 1
        }
        return line..<next
    }

    private mutating func recordSummary(
        takkuID: UUID, transcriptName: String, summary: SummaryOutcome, screenshots: [Screenshot]
    ) {
        if case .failed = summary, hasSuccessfulOutcome { return }
        var values: [(key: TakkuKey, value: String)] = [(.takkuID, takkuID.uuidString)]
        var blocks: [String] = []
        switch summary {
        case .written(let text, let template, let provider):
            values += [(.template, template), (.summaryProvider, provider)]
            blocks.append(text)
        case .transcriptOnly:
            removeFrontmatter([.template, .summaryProvider])
        case .failed(let reason):
            blocks.append("⚠️ Summary not generated: \(reason)")
        }
        // Those the Summary did not place under one of its points.
        let unplaced = screenshots.filter { !(blocks.first?.contains("![[\($0.fileName)") ?? false) }
        if !unplaced.isEmpty {
            blocks.append(Self.screenshotsHeading)
            blocks += unplaced.map { "**[\(elapsedLabel($0.time))]** ![[\($0.embed)]]" }
        }
        blocks.append("Full transcript: [[\(transcriptName)]]")
        setFrontmatter(values)
        replaceManagedSection(with: blocks.joined(separator: "\n\n"))
    }

    /// `47m`, or `1h 05m` past the hour. Never less than a minute.
    private static func durationValue(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes < 60 ? "\(minutes)m" : String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    /// A line of the model's reply (or of the notes given to an import) without what Obsidian would
    /// fetch or run by itself when the note is opened. The text comes from a Transcript that other
    /// people said, or from a video's description, so it is not trusted, and what is not known to be
    /// harmless is made harmless instead of looked for:
    /// - every Markdown image becomes a link (the address stays, nothing is loaded), whatever its
    ///   form; only the `![[…]]` embeds of the Vault stay, which are how Screenshots are placed;
    /// - an HTML tag is shown as text, but a few without attributes (`<br>`, `<b>`…);
    /// - a Dataview block, after any quote, list marker or fence length, is a plain block, and
    ///   an inline Dataview query is not one any more.
    private static func defused(_ line: String) -> String {
        var line = line
        line.replace(/!(?=\[(?!\[))/, with: "")
        line.replace(/<(?!\/?(?:br|b|i|u|s|sub|sup|kbd|mark|code|em|strong)\s*\/?>)(?=[A-Za-z\/!?])/, with: "&lt;")
        line.replace(/^((?:\s*(?:>|-|\*|\+|\d+[.)]))*\s*(?:`{3,}|~{3,})\s*)(?i:dataview(?:js)?)\b/) { "\($0.output.1)text" }
        line.replace(/`(\$?=)/, with: "` $1")
        return line
    }

    /// Which lines are inside a fenced code block, by CommonMark's rule: a block is closed by a fence of
    /// the same character, at least as long as the one that opened it, with nothing after it. Obsidian
    /// reads the note that way: a block Takku thought closed must not be one it thinks open.
    private struct Fences {
        private var open: (character: Character, length: Int)?

        var isInside: Bool { open != nil }

        /// The fence that closes the block that is still open.
        var closing: String? { open.map { String(repeating: $0.character, count: $0.length) } }

        /// Reads a line; `true` when it is a fence (opening or closing), which is not content.
        mutating func read(_ rawLine: String) -> Bool {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let character = line.first, character == "`" || character == "~" else { return false }
            let length = line.prefix { $0 == character }.count
            guard length >= 3 else { return false }
            let rest = line.dropFirst(length)
            if let current = open {
                guard character == current.character, length >= current.length,
                      rest.trimmingCharacters(in: .whitespaces).isEmpty
                else { return false }
                open = nil
                return true
            }
            // A backtick fence cannot have a backtick in its info string: it is not a fence then.
            guard character == "~" || !rest.contains("`") else { return false }
            open = (character, length)
            return true
        }
    }

    /// The fence that closes the code block still open at the end of `lines`, `nil` if there is none.
    private static func openFence(in lines: [String]) -> String? {
        var fences = Fences()
        for line in lines { _ = fences.read(line) }
        return fences.closing
    }

    /// Body lines that are Managed section markers, except those inside code blocks.
    private static func markerLines(in markdown: MarkdownLines) -> [(index: Int, marker: Marker)] {
        var markers: [(index: Int, marker: Marker)] = []
        var fences = Fences()
        for index in markdown.bodyStart..<markdown.lines.count {
            let line = markdown.lines[index].trimmingCharacters(in: .whitespaces)
            if fences.read(line) { continue }
            if !fences.isInside, let marker = Marker(line) {
                markers.append((index, marker))
            }
        }
        return markers
    }

    /// Lines from the start marker to the end marker included, if both are there and in order.
    private static func managedRange(in markdown: MarkdownLines) -> ClosedRange<Int>? {
        let markers = markerLines(in: markdown)
        guard let start = markers.firstIndex(where: { $0.marker == .start }),
              let end = markers[(start + 1)...].first(where: { $0.marker == .end })
        else { return nil }
        return markers[start].index...end.index
    }
}

extension DateFormatter {
    /// Fixed formatting, independent of the user's regional settings.
    static func posix(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
