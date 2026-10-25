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

    /// The content of a new Template created by the user: the default one with the chosen name.
    public static func newFileContent(name: String) -> String {
        defaultFileContent.replacingOccurrences(of: "name: \(defaultName)", with: "name: \(name)")
    }

    public init(fileName: String, content: String) {
        let markdown = MarkdownLines(content)
        name = markdown.value("name").flatMap { $0.isEmpty ? nil : $0 } ?? fileName
        summaryLanguage = markdown.value("summary_language").flatMap(Language.code)
        isFullText = markdown.value("full_text").map { ["true", "yes"].contains($0.lowercased()) } ?? false
        body = markdown.lines[markdown.bodyStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
