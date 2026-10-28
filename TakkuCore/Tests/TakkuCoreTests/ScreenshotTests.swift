import Foundation
import Testing
import TakkuCore

@Suite("Screenshots")
struct ScreenshotTests {
    let takkuID = UUID(uuidString: "6F1C2A00-0000-4000-8000-000000000001")!
    let rome = TimeZone(identifier: "Europe/Rome")!
    let transcript = Transcript(utterances: [
        Utterance(track: .others, start: 10, end: 20, text: "The deadline is Friday.", speaker: 1),
        Utterance(track: .me, start: 60, end: 70, text: "Ok."),
    ])

    @Test("named after the Meeting start and the time from it; the time is read back from the name")
    func names() throws {
        let startedAt = try Date("2026-10-04T12:30:00Z", strategy: .iso8601)

        #expect(Screenshot.baseName(startedAt: startedAt, time: 750.6, timeZone: rome) == "2026-10-04 1430 - 12m30s")
        #expect(Screenshot.baseName(startedAt: startedAt, time: 3930, timeZone: rome) == "2026-10-04 1430 - 1h05m30s")
        #expect(Screenshot(fileName: "2026-10-04 1430 - 12m30s.jpg")?.time == 750)
        #expect(Screenshot(fileName: "2026-10-04 1430 - 1h05m30s (2).jpg")?.time == 3930)
        #expect(Screenshot(fileName: "holiday.jpg") == nil)
        #expect(Screenshot(fileName: "2026-10-04 1430 - 12m30s.png") == nil)
    }

    @Test("in the Transcript file each one goes under the paragraph it falls in; before any speech, first")
    func inTranscriptFile() {
        let file = transcript.withScreenshots([
            Screenshot(embed: "c.jpg", time: 65),
            Screenshot(embed: "a.jpg", time: 3),
            Screenshot(embed: "b.jpg", time: 15),
            Screenshot(embed: "b2.jpg", time: 60),
        ]).vaultFile(takkuID: takkuID, meetingNoteName: "N", language: "en")

        #expect(file.hasSuffix("""
            ---
            ![[a.jpg]]

            **[00:10] Speaker 1:** The deadline is Friday.

            ![[b.jpg]]

            **[01:00] Me:** Ok.

            ![[b2.jpg]]

            ![[c.jpg]]

            """))
    }

    @Test("the Summary reads the Transcript without them, not even their names")
    func notInMarkdown() {
        let withScreenshots = transcript.withScreenshots([Screenshot(embed: "a.jpg", time: 15)])

        #expect(withScreenshots.markdown == transcript.markdown)
        #expect(withScreenshots.marking([15]).naming([1: "Mario Rossi"]).screenshots.map(\.embed) == ["a.jpg"])
    }

    @Test("read back from the Vault, image embeds are Screenshots, not text; other names take the paragraph's time")
    func parse() {
        let file = """
            ---
            takku_id: \(takkuID.uuidString)
            ---
            ![[2026-10-04 1430 - 0m03s.jpg]]

            **[00:10] Speaker 1:** The deadline is Friday.

            ![[2026-10-04 1430 - 0m15s.jpg]]
            ![[whiteboard.PNG|300]]
            ![[notes.pdf]]

            **[01:00] Me:** Ok.
            """

        let (parsed, _) = Transcript.parse(vaultFile: file)

        #expect(parsed.screenshots == [
            Screenshot(embed: "2026-10-04 1430 - 0m03s.jpg", time: 3),
            Screenshot(embed: "2026-10-04 1430 - 0m15s.jpg", time: 15),
            Screenshot(embed: "whiteboard.PNG|300", time: 10),
        ])
        #expect(parsed.paragraphs.map(\.text) == ["The deadline is Friday. ![[notes.pdf]]", "Ok."])
    }

    @Test("in the Summary each one goes under the first point citing its paragraph, smaller and in that point")
    func inSummary() async throws {
        let transcript = Transcript(utterances: [
            Utterance(track: .others, start: 10, end: 20, text: "The deadline is Friday.", speaker: 1),
            Utterance(track: .me, start: 90, end: 100, text: "I'll write to the client."),
            Utterance(track: .others, start: 200, end: 210, text: "Next topic.", speaker: 2),
            Utterance(track: .others, start: 400, end: 410, text: "Anything else?", speaker: 1),
        ]).withScreenshots([
            Screenshot(embed: "a.jpg", time: 15),
            Screenshot(embed: "b.jpg", time: 95),
            Screenshot(embed: "b2.jpg|300", time: 99),
            Screenshot(embed: "c.jpg", time: 230),
            Screenshot(embed: "d.jpg", time: 405),
            Screenshot(embed: "early.jpg", time: 2),
        ])
        let stub = StubTransport { _ in
            """
            ### Deadline

            - The deadline is Friday [00:10]
            - It was said again [00:10]
              1. Nested point [03:00-04:00]

            ### Actions

            - [ ] Mario Rossi writes to the client ([01:30])
            """
        }
        let prompt = SummaryPrompt(
            template: Template(fileName: "Notes", content: "### Topics"), personalNotes: "", transcript: transcript,
            meetingLanguage: "en"
        )

        let summary = try await Summarizer(
            client: ChatClient(baseURL: URL(string: "https://x.example/v1")!, apiKey: nil, model: "m", transport: stub.send),
            maxContextTokens: 32_000
        ).summarize(prompt)

        #expect(summary.text == """
            ### Deadline

            - The deadline is Friday
            - It was said again
              1. Nested point

            ### Actions

            - [ ] Mario Rossi writes to the client
            """)
        #expect(summary.withScreenshots == """
            ### Deadline

            - The deadline is Friday
              ![[a.jpg|400]]
            - It was said again
              1. Nested point
                 ![[c.jpg|400]]

            ### Actions

            - [ ] Mario Rossi writes to the client
              ![[b.jpg|400]]
              ![[b2.jpg|400]]
            """)
        #expect(stub.message(0, "user").map { !$0.contains(".jpg") } == true)
    }

    @Test("in the Managed section after the Summary, with their time; none, no heading")
    func inMeetingNote() {
        var note = MeetingNote.initial(takkuID: takkuID, startedAt: .now)
        let screenshots = [Screenshot(embed: "a.jpg", time: 3), Screenshot(embed: "b.jpg", time: 3930)]

        note.recordProcessing(
            takkuID: takkuID, duration: 60, language: "it", transcriptName: "T",
            summary: .written(text: "### Budget\n- Approved.", template: "Notes", provider: "Mistral EU"),
            screenshots: screenshots
        )
        #expect(note.content.contains("""
            %% takku:start %%
            ### Budget
            - Approved.

            ### Screenshots

            **[00:03]** ![[a.jpg]]

            **[1:05:30]** ![[b.jpg]]

            Full transcript: [[T]]
            %% takku:end %%
            """))

        note.recordRegeneration(
            takkuID: takkuID, transcriptName: "T",
            summary: .written(text: "- Approved.\n  ![[a.jpg|400]]", template: "Notes", provider: "Mistral EU"),
            screenshots: screenshots
        )
        #expect(note.content.contains("""
            %% takku:start %%
            - Approved.
              ![[a.jpg|400]]

            ### Screenshots

            **[1:05:30]** ![[b.jpg]]

            Full transcript: [[T]]
            """))

        note.recordRegeneration(takkuID: takkuID, transcriptName: "T", summary: .transcriptOnly, screenshots: screenshots)
        #expect(note.content.contains("""
            %% takku:start %%
            ### Screenshots

            **[00:03]** ![[a.jpg]]
            """))

        let previous = note.content
        note.recordRegeneration(takkuID: takkuID, transcriptName: "T", summary: .failed(reason: "-"))
        #expect(note.content == previous)
    }

    @Test("saved in the Recording folder and listed in time order; without the folder there are none")
    func load() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "takku-screenshots-\(UUID().uuidString)")
        let screenshots = folder.appending(path: Screenshot.folderName)
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(Screenshot.load(fromFolder: folder.appending(path: "missing")).isEmpty)
        for name in ["2026-10-04 1430 - 1m00s.jpg", "2026-10-04 1430 - 0m05s.jpg", "other.jpg"] {
            try Data().write(to: screenshots.appending(path: name))
        }
        #expect(Screenshot.load(fromFolder: folder).map(\.time) == [5, 60])
    }
}
