import Foundation

/// A file in `~/.takku/templates` that defines the structure and instructions of the Summary for a kind of Meeting.
public struct Template: Equatable, Sendable {
    public let name: String
    /// Language code that forces the Summary language (`it`, `en`, `fr`…), `nil` to use the Meeting's.
    public let summaryLanguage: String?
    /// Free-form instructions and structure, passed to the model as they are.
    public let body: String
    /// `full_text: true`: the whole Transcript rewritten with the Template (e.g. the full text of
    /// a lecture), in blocks of about 10 minutes joined in order, instead of a Summary.
    public let isFullText: Bool
    /// `folder: YouTube`: where a file imported with this Template gets its note, inside the notes
    /// folder (checked as `VaultNaming.noteFolder`; an invalid one is ignored). `nil`: `Meetings/`.
    /// Recorded Meetings always go in `Meetings/`.
    public let folder: String?

    /// The Template Takku creates when the Templates folder is empty: notes by
    /// topic, in Meeting order, and Next steps at the end (like Granola).
    public static let defaultName = "Notes"
    public static let defaultFileContent = """
        ---
        name: Notes
        summary_language: auto
        ---
        Write the meeting notes the way an attentive colleague would take them, not as formal minutes.

        - Split the meeting into topics, in the order they were discussed. For each topic \
        a `###` heading with a short, concrete title. In a stand-up or round-table, one topic per project, not per person.
        - Under each topic a bullet list: one bullet per idea, proposal, decision or problem, \
        with sub-bullets for reasons, details, figures, dates and links. Short sentences, no preambles.
        - Say who proposes, decides or reports something only when the Transcript makes it clear; \
        otherwise write the bullet without a subject.
        - Decisions go in the topic they belong to, not in a separate section.
        - Leave out greetings, problems with the call and passages that make no sense.
        - No opening summary and no generic conclusions.

        ### Next steps
        One bullet per action someone took on in this meeting, in the form `- [ ] What to do (Who)`, \
        with a sub-bullet for the deadline or what it depends on, without labels such as "Context:".
        Not actions: work already in progress that someone reports, waiting for others, attending a meeting already planned.
        With no actions, leave out this section, heading included.
        Write every heading, this one included, in the language of the summary.

        """

    /// The Templates Takku creates next to Notes in an empty Templates folder, by file name: study
    /// notes of a lecture, and its full text.
    public static let builtInFiles: [(name: String, content: String)] = [
        ("Lecture", lectureFileContent),
        ("Full text", fullTextFileContent),
    ]

    static let lectureFileContent = """
        ---
        name: Lecture
        summary_language: auto
        ---
        Write study notes of a university lecture, the way a careful student would write them up after class: complete enough that someone who missed the lecture can study from them. This is a lecture, not a meeting: one lecturer speaks most of the time, students ask the occasional question.

        ### In this lecture
        Two to four bullets: what the lecture covers and how it connects to what came before, when the lecturer says so.

        Then the topics, in the order they were taught:

        - For each topic a `###` heading with the name of the concept, not a generic title.
        - Under each topic a bullet list: definitions, explanations, the reasoning step by step, the examples and figures the lecturer gives, with sub-bullets for details. Keep the lecturer's examples: they are what makes a concept stick.
        - Write a definition as `**Term**: what it means`.
        - Write formulas in LaTeX between `$…$`, with what each symbol stands for.
        - When the lecturer stresses something (it is important, it comes up at the exam, a common mistake), write it as a bullet starting with ⚠️.
        - A student's question and the lecturer's answer go under the topic they are about, as a bullet starting with "Question:", the answer in a sub-bullet.
        - Never write who is speaking: no "the lecturer says", no "Speaker 1". Write the content directly.
        - Recognition gets technical terms wrong: write the correct term when the subject makes it certain (e.g. "procedura di infrazione", not "procedura di interazione"; "MEF", not "MEFA"). When it is not certain, leave the passage out.
        - Leave out greetings, microphone checks, breaks, roll call and passages that make no sense.

        ### Key terms
        The terms defined in the lecture, one bullet each, `**Term**: short definition`, in alphabetical order. Leave out this section, heading included, if no term is defined.

        ### Course and exam
        What the lecturer says about the exam, assignments, readings, slides, deadlines and the next lectures, as a checklist `- [ ] What to do`, with the date or the chapter in a sub-bullet. Leave out this section, heading included, if nothing is said about it.

        ### Review questions
        Three to six questions a student could be asked at the exam on this lecture, each answerable from these notes. Only questions on what was taught.

        Write every heading, these ones included, in the language of the summary.

        """

    static let fullTextFileContent = """
        ---
        name: Full text
        summary_language: auto
        full_text: true
        ---
        Write the full text of a university lecture, not a summary. A student will study from it instead of the recording, so nothing taught may be lost: every concept, definition, step of the reasoning, example, number, date, name, reference and digression on the subject stays, in the order it was said. The result is about as long as the Transcript, only cleaner. Do not shorten, do not merge passages into a general statement, do not skip a part because it repeats an idea in other words: keep what it adds.

        How to clean it:

        - Write in prose, in the lecturer's voice and tense, as a written text: full sentences grouped in paragraphs, not bullets.
        - Remove only what is not content: hesitations, "ehm", false starts, words repeated while thinking, "okay?", "right?", microphone checks, greetings, breaks, roll call.
        - Who is who: the Speaker who talks most of the time is the lecturer; the other Speakers, and "Others", are students. Never present what a student says as the lecturer's words, and never call a student "a lecturer".
        - Recognition gets technical terms wrong: write the correct term when the subject makes it certain (e.g. "procedura di infrazione", not "procedura di interazione" or "procedura per inflazione"; "MEF", not "MEFA"; "disavanzo", not "disavaggio"). Once you correct a term, correct it the same way everywhere it comes back, in the lecturer's words and in the students' alike.
        - The same holds for well-known names (politicians, economists, institutions): write them right when the context makes them certain (e.g. "Meloni", not "Miloni"), instead of replacing them with a generic "a minister".
        - When a passage makes no sense and the subject does not make it certain, write it as close to the Transcript as possible followed by "[?]", instead of leaving it out.
        - Split the text with a `###` heading at every change of topic, named after the concept; under it the paragraphs of that part.
        - Write the terms the lecturer defines in **bold** the first time.
        - Write formulas in LaTeX between `$…$`.
        - What a student says goes where it was said: a question as a paragraph starting with "**Question:**", a remark or an example as a paragraph starting with "**Remark:**", both words in the language of the summary, in the student's own words, cleaned like the rest. The lecturer's answer follows, in the lecturer's voice.
        - What the lecturer says about the exam, readings, slides and deadlines stays where it was said, in a paragraph starting with "⚠️".
        - Never write who is speaking ("the lecturer says", "Speaker 1"): write the content directly.
        - End every paragraph with the time of the Transcript passage it comes from, as for the bullets.

        Write every heading in the language of the summary.

        """

    /// The content of a new Template created by the user: the default one with the chosen name.
    public static func newFileContent(name: String) -> String {
        defaultFileContent.replacingOccurrences(of: "name: \(defaultName)", with: "name: \(name)")
    }

    public init(fileName: String, content: String) {
        let markdown = MarkdownLines(content)
        name = markdown.value("name").flatMap { $0.isEmpty ? nil : $0 } ?? fileName
        summaryLanguage = markdown.value("summary_language").flatMap(Language.code)
        isFullText = markdown.value("full_text").map { ["true", "yes"].contains($0.lowercased()) } ?? false
        folder = markdown.value("folder").flatMap { try? VaultNaming.noteFolder($0).get() }
        body = markdown.lines[markdown.bodyStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
