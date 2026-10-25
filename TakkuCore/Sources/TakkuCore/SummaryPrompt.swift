import Foundation

/// What Takku asks the model in order to write the Summary of a Meeting.
///
/// The instructions are in English; the Summary language is stated explicitly
/// ("Write the summary in Italian"), so any language works.
public struct SummaryPrompt: Sendable {
    private let template: Template
    private let personalNotes: String
    let transcript: Transcript
    private let meetingLanguage: String?
    private let vocabulary: Vocabulary
    private let userName: String?
    private let participants: [String]

    /// `userName` is who "Me" is in the Transcript, so the Summary names them as the others call them.
    /// `participants`: who the calendar event invited, as the Meeting note lists them now.
    public init(
        template: Template, personalNotes: String, transcript: Transcript, meetingLanguage: String?,
        vocabulary: Vocabulary = .empty, userName: String? = nil, participants: [String] = []
    ) {
        self.template = template
        self.personalNotes = personalNotes
        self.transcript = transcript
        self.meetingLanguage = meetingLanguage
        self.vocabulary = vocabulary
        self.userName = userName.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        self.participants = participants
    }

    /// Language code: the Template's, else the Meeting's, else Italian.
    public var summaryLanguage: String {
        template.summaryLanguage ?? meetingLanguage ?? "it"
    }

    /// A single request with the whole Transcript.
    public func singleRequest() -> [ChatMessage] {
        [
            ChatMessage(role: .system, content: systemRules),
            ChatMessage(role: .user, content: """
                \(templateAndNotes)

                # Transcript
                \(transcript.markdown.trimmingCharacters(in: .newlines))
                """),
        ]
    }

    /// Room left for the model's reply in every request.
    public static let replyReserveTokens = 4_096

    /// Conservative estimate: about 3 characters per token (Italian uses more tokens than English).
    static func estimatedTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + $1.content.count / 3 + 4 }
    }

    func fits(maxContextTokens: Int) -> Bool {
        Self.estimatedTokens(singleRequest()) + Self.replyReserveTokens <= maxContextTokens
    }

    /// The Transcript split into blocks of consecutive paragraphs, one request per block.
    /// A paragraph is never split: if it alone exceeds the room, it forms its own block.
    func partialRequests(maxContextTokens: Int) -> [[ChatMessage]] {
        let overhead = Self.estimatedTokens(partialRequest(part: 1, of: 1, transcript: ""))
        let budget = max(1, (maxContextTokens - Self.replyReserveTokens - overhead) * 3)

        var blocks: [[Paragraph]] = []
        var size = 0
        for paragraph in transcript.paragraphs {
            let length = Transcript.markdown(of: [paragraph]).count + 1
            if blocks.isEmpty || size + length > budget {
                blocks.append([])
                size = 0
            }
            blocks[blocks.count - 1].append(paragraph)
            size += length
        }
        return blocks.enumerated().map { index, block in
            partialRequest(
                part: index + 1, of: blocks.count,
                transcript: Transcript.markdown(of: block).trimmingCharacters(in: .newlines)
            )
        }
    }

    func mergeFits(partials: [String], maxContextTokens: Int) -> Bool {
        Self.estimatedTokens(mergeRequest(partials: partials)) + Self.replyReserveTokens <= maxContextTokens
    }

    /// When the merge does not fit in the context: consecutive partial summaries are grouped
    /// and every group becomes a single summary, one request per group.
    func groupRequests(partials: [String], maxContextTokens: Int) -> [[ChatMessage]] {
        let overhead = Self.estimatedTokens(groupRequest(""))
        let budget = max(1, (maxContextTokens - Self.replyReserveTokens - overhead) * 3)
        var groups: [[String]] = []
        var size = 0
        for partial in partials {
            if groups.isEmpty || size + partial.count + 2 > budget {
                groups.append([])
                size = 0
            }
            groups[groups.count - 1].append(partial)
            size += partial.count + 2
        }
        return groups.map { groupRequest($0.joined(separator: "\n\n")) }
    }

    // MARK: - Full text

    /// The Template asks for the whole Transcript rewritten, not summarised.
    var isFullText: Bool { template.isFullText }

    /// About this much of the Meeting per request with a full-text Template: as long as the first
    /// ten minutes of a 75-minute lecture, which a single request kept at 71% against 37–49% for the rest.
    static let fullTextBlockDuration: TimeInterval = 600

    /// The Transcript in consecutive blocks of about `fullTextBlockDuration`, never splitting a
    /// paragraph. The reply is about as long as its block, so a block takes at most half of the
    /// context left after the rules: a small context gets shorter blocks.
    func fullTextBlocks(maxContextTokens: Int) -> [[Paragraph]] {
        let overhead = Self.estimatedTokens(fullTextRequest(part: 1, of: 2, paragraphs: [], previousHeading: "### Heading"))
        let budget = max(1, (maxContextTokens - overhead) / 2 * 3)
        var blocks: [[Paragraph]] = []
        var blockStart: TimeInterval = 0
        var size = 0
        for paragraph in transcript.paragraphs {
            let length = Transcript.markdown(of: [paragraph]).count + 1
            if blocks.isEmpty || paragraph.start - blockStart >= Self.fullTextBlockDuration || size + length > budget {
                blocks.append([])
                blockStart = paragraph.start
                size = 0
            }
            blocks[blocks.count - 1].append(paragraph)
            size += length
        }
        return blocks
    }

    /// One block rewritten in full with the Template and all the rules of a single request.
    /// `previousHeading`: the last heading of the part before, to go on under it.
    func fullTextRequest(part: Int, of count: Int, paragraphs: [Paragraph], previousHeading: String?) -> [ChatMessage] {
        var transcriptHeading = "# Transcript"
        if count > 1 {
            transcriptHeading += ", part \(part) of \(count)\n"
                + "The Transcript is long: it is written part by part and the parts are joined in order. "
                + "Write this part in full, following the Template, with no introduction or conclusion of the whole."
            if let previousHeading {
                transcriptHeading += " The previous part ended under the heading `\(previousHeading)`: "
                    + "go on under it, without writing it again, until the topic changes."
            }
        }
        return [
            ChatMessage(role: .system, content: systemRules),
            ChatMessage(role: .user, content: """
                \(templateAndNotes)

                \(transcriptHeading)
                \(Transcript.markdown(of: paragraphs).trimmingCharacters(in: .newlines))
                """),
        ]
    }

    /// The last Markdown heading of a part, as written.
    static func lastHeading(in part: String) -> String? {
        part.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("#") }
    }

    /// The parts written in full, in order; a part that opens with the heading the previous one
    /// ended under (the model repeats it despite being told) does not write it again.
    static func joiningFullTextParts(_ parts: [String]) -> String {
        var joined: [String] = []
        var previousHeading: String?
        for part in parts {
            var lines = part.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            if let previousHeading, lines.first?.trimmingCharacters(in: .whitespaces) == previousHeading {
                lines.removeFirst()
            }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { joined.append(text) }
            previousHeading = lastHeading(in: part) ?? previousHeading
        }
        return joined.joined(separator: "\n\n")
    }

    /// Merges the partial summaries into a Summary that follows the Template.
    func mergeRequest(partials: [String]) -> [ChatMessage] {
        let parts = partials.enumerated()
            .map { "Part \($0.offset + 1) of \(partials.count):\n\($0.element)" }
            .joined(separator: "\n\n")
        return [
            ChatMessage(role: .system, content: systemRules),
            ChatMessage(role: .user, content: """
                \(templateAndNotes)

                # Transcript
                The Transcript was too long for a single request: below are summaries of its parts, in order.

                \(parts)
                """),
        ]
    }

    private var systemRules: String {
        """
        You are Takku and you write the summary of a meeting from its Transcript.

        Rules:
        - Write the summary in \(languageName), whatever language the instructions are written in.
        - Follow the structure and instructions of the Template.
        - Do not invent: use only what is in the Transcript and in the personal notes. \(Self.nonsenseRule)
        - For every bullet, actions included, end it with the time of the Transcript passage it comes from, in square brackets as in the Transcript: `[12:34]`, or `[03:10] [07:45]` for several. Leave out what you cannot point to in the Transcript or in the personal notes. Takku removes the times before showing the summary: do not mention them otherwise.
        - \(Self.truncationRule)
        - \(meRule)
        - \(Self.speakersRule)\(namedSpeakersRule.map { "\n- " + $0 } ?? "")\(participantsRule.map { "\n- " + $0 } ?? "")
        - The personal notes say what matters to the person who wrote them: give those topics priority. \(Self.pastedNotesRule)\(marksRule.map { "\n- " + $0 } ?? "")
        - Write actions as a `- [ ]` checklist, in the format the Template asks for; if it asks for none, `- [ ] who: what (when)`. \(Self.actionsRule) Write who only when the Transcript makes clear who took the action on: a name in the personal notes\(participants.isEmpty ? "" : " or among the invited participants") is not enough. Leave out who or when if they are not clear, with nothing in their place.
        - Reply with the summary in Markdown only, without preambles.
        """ + vocabularyBlock
    }

    /// "Me" is a Track label, not a name: written as is it reads "Me ha esplorato…", and without the
    /// user's name the model takes "Mario", as the others call them, for someone else.
    private var meRule: String {
        if let userName {
            """
            In the Transcript "Me" is \(userName), the person who took the personal notes; the others may call them by their first name. In the summary write about them by name like any other participant, never as "Me".
            """
        } else {
            """
            In the Transcript "Me" is the person who took the personal notes. Never write "Me" in the summary: if a name they answer to is clear, use it, otherwise leave out who.
            """
        }
    }

    /// Speakers are told apart by voice only: their names come from what is said, when it is clear.
    /// An unnamed Speaker keeps the label only on an action, where "who" is worth a guess for the reader;
    /// elsewhere the model kept writing "Speaker N" until it was shown the sentence without a subject.
    private static let speakersRule = """
        The other participants are "Speaker 1", "Speaker 2"…, told apart by their voice: the same number is the same person throughout the Transcript, but a short reply can be given to the wrong one. \(othersRule) A Speaker's name is the one they introduce themselves with, or the one they answer to when called: use it for what that Speaker says and takes on. For a Speaker without a name, say who they are if it is clear (e.g. "the supplier's team"). Otherwise write "Speaker N" only as who takes on an action; everywhere else leave out who and write the bullet without a subject (e.g. "It is proposed to…" instead of "Speaker 2 proposes…"): never "Speaker N" in a heading or in the other bullets.
        """

    /// In the summaries of the parts of a long Meeting a Speaker's name may only come up in
    /// another part: the label is kept so the final summary can still name them.
    private static let partialSpeakersRule = """
        The other participants are "Speaker 1", "Speaker 2"…, told apart by their voice: the same number is the same person in every part. \(othersRule) A Speaker's name is the one they introduce themselves with, or the one they answer to when called: write "Speaker N (Name)" when it is clear, otherwise keep "Speaker N".
        """

    /// "Others" is several voices under one label: with the names of the personal notes or of the
    /// invitation at hand, the model handed them out to its paragraphs and got who did what wrong.
    private static let othersRule = """
        "Others" is anyone not told apart, often several people: give it a name only in a passage where the Transcript itself says who is speaking (e.g. "Mario, your turn" just before).
        """

    /// Personal notes are not always notes: an email pasted before the call or the list of the people
    /// in it were taken for what was said or decided, and the list for who said it.
    private static let pastedNotesRule = """
        They may also hold material pasted by the user, such as an email or a list of people: use it to understand the meeting, but it is not what was said or decided in it, and a name in the notes does not say who spoke.
        """

    /// In stand-ups every update turned into an action, and a Meeting without any got a
    /// "- [ ] No actions agreed" line.
    private static let actionsRule = """
        An action is something someone took on in this meeting: work in progress that someone reports, waiting for others or attending a meeting already planned are not actions. With no actions, write none and no line saying there are none.
        """

    /// Recognition errors (an impossible year, three dates that cannot all be right) were copied
    /// into the Summary as facts.
    private static let nonsenseRule = """
        Leave out passages that make no sense, such as a misheard figure or date, instead of copying them.
        """

    /// "Name (Speaker N)" in the Transcript: the user named that Speaker in the Meeting note.
    private var namedSpeakersRule: String? {
        guard transcript.hasNamedSpeakers else { return nil }
        return """
            "Name (Speaker N)" in the Transcript is a name the user gave that Speaker: it is certain, always write that name for what they say and take on.
            """
    }

    /// Who was invited is not who spoke: a guess by elimination would put words in the wrong mouth.
    private var participantsRule: String? {
        guard !participants.isEmpty else { return nil }
        return """
            The invited participants are who the calendar invitation asked to join, not who spoke, and some may not have joined: a Speaker's name can be one of them only when the Transcript makes it clear, or when there is exactly one invited participant and one Speaker. Use them to spell names right.
            """
    }

    /// The user marked these paragraphs while recording (⌃⌥⌘M).
    private var marksRule: String? {
        guard transcript.paragraphs.contains(where: \.isMarked) else { return nil }
        return """
            Paragraphs starting with \(Transcript.markSymbol) were marked as important by the user during the meeting: give them priority, like the topics of the personal notes.
            """
    }

    /// A Recording stopped before the end of the Meeting leaves a Transcript cut mid-sentence: models
    /// tend to complete what was announced (the rest of a talk, its results) from what they know.
    private static let truncationRule = """
        The Transcript may stop mid-sentence, when the recording ended before the meeting: summarise only what it contains, and do not complete talks, lists, steps or results that are announced but not reached.
        """

    /// The Summary without the times the model cites (`[12:34]`, `[03:10] [07:45]`, `([1:02:45])`,
    /// `[04:00-06:30]`): they tie every point to the Transcript but are not meant to be read.
    /// Checkboxes, wikilinks and Markdown links have no times in their brackets and stay.
    public static func removingCitedTimes(_ summary: String) -> String {
        let time = #"\d{1,2}(?::\d{2}){1,2}"#
        let bracket = #"\[\#(time)(?:\s*[-–—,;]\s*\#(time))*\]"#
        let run = #"\#(bracket)(?:[ \t]*[,;]?[ \t]*\#(bracket))*"#
        let citedTimes = try! Regex(#"[ \t]*(?:\(\#(run)\)|\#(run))"#)
        return summary.replacing(citedTimes, with: "")
    }

    /// The Summary without the stars of the marked paragraphs, which the model sometimes copies:
    /// they tell it what matters, they are not meant to be read.
    public static func removingMarks(_ summary: String) -> String {
        // The emoji variant (⭐️) is another grapheme: made plain first, so one pattern covers both.
        summary
            .replacingOccurrences(of: Transcript.markSymbol + "\u{FE0F}", with: Transcript.markSymbol)
            // At the end of a line the spaces before it go too; elsewhere those after it.
            .replacing(try! Regex("[ \t]*\(Transcript.markSymbol)[ \t]*(?=\n|$)"), with: "")
            .replacing(try! Regex("\(Transcript.markSymbol)[ \t]*"), with: "")
    }

    /// The Vocabulary for the system prompt of any request, with a blank line before it; empty without one.
    private var vocabularyBlock: String {
        vocabulary.promptBlock.map { "\n\n" + $0 } ?? ""
    }

    private func partialRequest(part: Int, of count: Int, transcript: String) -> [ChatMessage] {
        [
            ChatMessage(role: .system, content: """
                You are Takku. You receive part \(part) of \(count) of the Transcript of a meeting.
                Summarise it faithfully and compactly, in \(languageName): topics, decisions, actions (who, what, when) and open questions, with timestamps.
                \(meRule)
                \(Self.partialSpeakersRule)\(namedSpeakersRule.map { "\n" + $0 } ?? "")\(marksRule.map { "\n" + $0 } ?? "")
                The personal notes say what matters to the person who wrote them. \(Self.pastedNotesRule)
                Do not invent. \(Self.nonsenseRule) \(Self.truncationRule)
                Reply with the summary only.
                """ + vocabularyBlock),
            ChatMessage(role: .user, content: """
                # Personal notes
                \(notesOrNone)
                \(participantsBlock)
                # Transcript, part \(part) of \(count)
                \(transcript)
                """),
        ]
    }

    private func groupRequest(_ partials: String) -> [ChatMessage] {
        [
            ChatMessage(role: .system, content: """
                You are Takku. You receive the summaries of consecutive parts of the same meeting.
                Merge them into a single faithful and compact summary, in \(languageName): topics, decisions, actions (who, what, when) and open questions, with timestamps.
                "Speaker N" is the same person in every summary: keep it, with the name if one of them gives it.
                Do not invent. Reply with the summary only.
                """ + vocabularyBlock),
            ChatMessage(role: .user, content: """
                # Personal notes
                \(notesOrNone)

                # Summaries of consecutive parts
                \(partials)
                """),
        ]
    }

    private var templateAndNotes: String {
        """
        # Template
        \(template.body)

        # Personal notes
        \(notesOrNone)\(participantsBlock.isEmpty ? "" : "\n\n" + participantsBlock.trimmingCharacters(in: .newlines))
        """
    }

    /// The invited participants as a section of the user message, with a blank line after it; empty without any.
    private var participantsBlock: String {
        guard !participants.isEmpty else { return "" }
        return "\n# Invited participants\n" + participants.map { "- \($0)" }.joined(separator: "\n") + "\n"
    }

    private var notesOrNone: String {
        personalNotes.isEmpty ? "(none)" : personalNotes
    }

    private var languageName: String {
        Language.name(summaryLanguage)
    }
}
