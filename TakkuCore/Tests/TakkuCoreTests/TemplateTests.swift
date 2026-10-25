import Testing
import TakkuCore

@Suite("Summary Template")
struct TemplateTests {
    @Test("the file gives name, Summary language and body")
    func parse() {
        let template = Template(fileName: "1-1 weekly", content: """
            ---
            name: 1:1 weekly
            summary_language: it
            ---
            Focus on blockers and decisions.

            ### Topics
            ### Next steps
            """)

        #expect(template.name == "1:1 weekly")
        #expect(template.summaryLanguage == "it")
        #expect(template.body == "Focus on blockers and decisions.\n\n### Topics\n### Next steps")
    }

    @Test("without frontmatter the name is the file's and the language follows the Meeting")
    func withoutFrontmatter() {
        let template = Template(fileName: "Retro", content: "### What went well\n### What to improve\n")

        #expect(template.name == "Retro")
        #expect(template.summaryLanguage == nil)
        #expect(template.body == "### What went well\n### What to improve")
    }

    @Test("summary_language accepts any language code; auto or empty means the Meeting's language", arguments: [
        ("fr", "fr"),
        ("DE", "de"),
        ("pt-BR", "pt-br"),
        ("auto", nil),
        ("", nil),
        ("not a language", nil),
    ] as [(String, String?)])
    func language(value: String, expected: String?) {
        let template = Template(fileName: "T", content: "---\nsummary_language: \(value)\n---\nBody")

        #expect(template.summaryLanguage == expected)
    }

    @Test("full_text: true asks for the whole Transcript rewritten, not summarised; anything else or nothing is a Summary", arguments: [
        ("full_text: true", true),
        ("full_text: yes", true),
        ("full_text: false", false),
        ("full_text: ", false),
        ("summary_language: it", false),
    ])
    func fullText(line: String, expected: Bool) {
        let template = Template(fileName: "T", content: "---\n\(line)\n---\nBody")

        #expect(template.isFullText == expected)
    }

    @Test("the default Notes Template asks for topics in Meeting order and Next steps at the end")
    func defaultTemplate() {
        let template = Template(fileName: "Notes", content: Template.defaultFileContent)

        #expect(template.name == "Notes")
        #expect(template.summaryLanguage == nil)
        #expect(template.body.contains("in the order they were discussed"))
        #expect(template.body.contains("### Next steps"))
        #expect(template.body.contains("- [ ] What to do (Who)"))
        #expect(template.body.contains("Not actions: work already in progress that someone reports"))
        #expect(template.body.contains("With no actions, leave out this section, heading included."))
        #expect(template.body.contains("Write every heading, this one included, in the language of the summary."))
    }

    @Test("a new Template starts from the default one with the chosen name")
    func newTemplate() {
        let template = Template(fileName: "Sprint retro", content: Template.newFileContent(name: "Sprint retro"))
        let base = Template(fileName: Template.defaultName, content: Template.defaultFileContent)

        #expect(template.name == "Sprint retro")
        #expect(template.summaryLanguage == nil)
        #expect(template.body == base.body)
    }

    @Test("the default Template contains no stray backslashes from line continuations")
    func noStrayBackslashes() {
        #expect(!Template.defaultFileContent.contains("\\"))
    }
}
