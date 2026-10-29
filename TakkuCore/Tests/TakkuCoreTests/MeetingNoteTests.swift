import Foundation
import Testing
import TakkuCore

@Suite("Meeting note")
struct MeetingNoteTests {
    let rome = TimeZone(identifier: "Europe/Rome")!
    let takkuID = UUID(uuidString: "6F1C2A00-0000-4000-8000-000000000001")!
    /// 4 October 2026, 14:30 in Rome.
    let startedAt = Date(timeIntervalSince1970: 1_791_117_000)

    @Test("at start the note has frontmatter, the managed section and a section for personal notes")
    func initialContent() {
        let note = MeetingNote.initial(takkuID: takkuID, startedAt: startedAt, timeZone: rome)

        #expect(note.content == """
            ---
            takku_id: 6F1C2A00-0000-4000-8000-000000000001
            date: 2026-10-04T14:30
            tags: [meeting]
            ---
            %% takku:start %%
            ⏺ Recording in progress: the summary will appear here after you stop.
            %% takku:end %%

            ## Personal notes


            """)
    }

    @Test("an imported Meeting starts queued for Processing, not recording")
    func importedInitialContent() {
        let note = MeetingNote.initial(takkuID: takkuID, startedAt: startedAt, timeZone: rome, isImport: true)

        #expect(note.content.contains("⏳ Imported recording queued for Processing."))
        #expect(!note.content.contains("Recording in progress"))
    }

    @Test("rewriting the managed section leaves everything else untouched")
    func replaceManagedSection() {
        var note = MeetingNote(content: """
            ---
            takku_id: 1
            ---
            Note written above.
            %% takku:start %%
            ⏺ Recording in progress.
            %% takku:end %%

            ## Personal notes

            - ask Mario about the budget
            """)

        note.replaceManagedSection(with: "### Budget\n\nAll good.")

        #expect(note.content == """
            ---
            takku_id: 1
            ---
            Note written above.
            %% takku:start %%
            ### Budget

            All good.
            %% takku:end %%

            ## Personal notes

            - ask Mario about the budget
            """)
    }

    @Test("if one or both markers are missing, the managed section is recreated at the top of the body")
    func missingMarkers() {
        var note = MeetingNote(content: """
            ---
            takku_id: 1
            ---
            %% takku:start %%
            Text left after the user deleted the end marker.

            ## Personal notes

            - important point
            """)

        note.replaceManagedSection(with: "Summary.")

        #expect(note.content == """
            ---
            takku_id: 1
            ---
            %% takku:start %%
            Summary.
            %% takku:end %%

            Text left after the user deleted the end marker.

            ## Personal notes

            - important point
            """)
    }

    @Test("without frontmatter the recreated managed section goes at the top of the file")
    func missingMarkersWithoutFrontmatter() {
        var note = MeetingNote(content: "Just notes.\n")

        note.replaceManagedSection(with: "Summary.")

        #expect(note.content == "%% takku:start %%\nSummary.\n%% takku:end %%\n\nJust notes.\n")
    }

    @Test("markers inside a code block do not count: personal notes stay intact")
    func markersInsideCodeBlock() {
        var note = MeetingNote(content: """
            ---
            takku_id: 1
            ---
            %% takku:start %%
            Old summary.

            ## Personal notes

            ```
            %% takku:end %%
            ```
            """)

        note.replaceManagedSection(with: "New.")

        #expect(note.content == """
            ---
            takku_id: 1
            ---
            %% takku:start %%
            New.
            %% takku:end %%

            Old summary.

            ## Personal notes

            ```
            %% takku:end %%
            ```
            """)
    }

    @Test("a marker in the text being written is removed: it must not be able to close the managed section")
    func markersInBodyAreRemoved() {
        var note = MeetingNote(content: "%% takku:start %%\nOld.\n%% takku:end %%\n\nNotes.")

        note.replaceManagedSection(with: "Summary.\n%% takku:end %%\nMore.")

        #expect(note.content == "%% takku:start %%\nSummary.\nMore.\n%% takku:end %%\n\nNotes.")
    }

    @Test("a note with Windows line endings and a BOM is read correctly")
    func windowsLineEndings() {
        var note = MeetingNote(content: "\u{FEFF}---\r\ntakku_id: 1\r\n---\r\n%% takku:start %%\r\nOld.\r\n%% takku:end %%\r\n")

        note.setFrontmatter([(.language, "it")])
        note.replaceManagedSection(with: "New.")

        #expect(note.content == "---\ntakku_id: 1\nlanguage: it\n---\n%% takku:start %%\nNew.\n%% takku:end %%\n")
    }

    @Test("a frontmatter closing line with trailing spaces is recognised, horizontal rules in the body are not")
    func frontmatterCloseWithTrailingSpace() {
        var note = MeetingNote(content: "---\ntakku_id: 1\n---  \nBefore.\n\n---\n\nAfter.")

        note.setFrontmatter([(.language, "it")])

        #expect(note.content == "---\ntakku_id: 1\nlanguage: it\n---  \nBefore.\n\n---\n\nAfter.")
        #expect(note.personalNotes == "Before.\n\n---\n\nAfter.")
    }

    @Test("Takku updates its frontmatter keys and adds missing ones, leaving the user's keys alone")
    func frontmatter() {
        var note = MeetingNote(content: """
            ---
            takku_id: 1
            date: 2026-10-04T14:30
            project: Unipol
            tags:
              - meeting
              - client
            language:
              - en
            duration: 1m
            ---
            Body.
            """)

        note.setFrontmatter([
            (.duration, "47m"),
            (.language, "it"),
            (.transcript, MeetingNote.wikiLink("2026-10-04 1430 - Meeting (transcript)")),
        ])

        #expect(note.content == """
            ---
            takku_id: 1
            date: 2026-10-04T14:30
            project: Unipol
            tags:
              - meeting
              - client
            language: it
            duration: 47m
            transcript: "[[2026-10-04 1430 - Meeting (transcript)]]"
            ---
            Body.
            """)
    }

    @Test("a note without frontmatter gets one with Takku's keys")
    func frontmatterCreated() {
        var note = MeetingNote(content: "Body.")

        note.setFrontmatter([(.language, "it")])

        #expect(note.content == "---\nlanguage: it\n---\nBody.")
    }

    @Test("takku_id is read from the frontmatter only")
    func readsTakkuIDFromFrontmatter() {
        let id = "6F1C2A00-0000-4000-8000-000000000001"

        #expect(MeetingNote(content: "---\ntakku_id: \(id)\n---\nBody.").takkuID == UUID(uuidString: id))
        #expect(MeetingNote(content: "---\ntitle: x\n---\ntakku_id: \(id)\n").takkuID == nil)
        #expect(MeetingNote(content: "takku_id: \(id)\n").takkuID == nil)
    }

    @Test("personal notes are the whole body outside the managed section, without the heading")
    func personalNotes() {
        let note = MeetingNote(content: """
            ---
            takku_id: 1
            ---
            Note written above.
            %% takku:start %%
            ### Summary
            Not the user's.
            %% takku:end %%

            ## Personal notes

            - ask Mario about the budget
            - risk: supplier is late

            """)

        #expect(note.personalNotes == """
            Note written above.

            - ask Mario about the budget
            - risk: supplier is late
            """)
    }

    @Test("a freshly created note has no personal notes")
    func noPersonalNotes() {
        let note = MeetingNote.initial(takkuID: takkuID, startedAt: startedAt, timeZone: rome)

        #expect(note.personalNotes.isEmpty)
    }

    @Test("at the end of Processing the note gets the Summary, the Transcript link and Takku's keys")
    func processingRecorded() {
        var note = MeetingNote.initial(takkuID: takkuID, startedAt: startedAt, timeZone: rome)

        note.recordProcessing(
            takkuID: takkuID, duration: 47 * 60 + 10, language: "it",
            transcriptName: "2026-10-04 1430 - Meeting (transcript)",
            summary: .written(text: "### Budget\n- Approved.", template: "Notes", provider: "Mistral EU")
        )

        #expect(note.content == """
            ---
            takku_id: 6F1C2A00-0000-4000-8000-000000000001
            date: 2026-10-04T14:30
            tags: [meeting]
            duration: 47m
            transcript: "[[2026-10-04 1430 - Meeting (transcript)]]"
            language: it
            template: Notes
            summary_provider: Mistral EU
            ---
            %% takku:start %%
            ### Budget
            - Approved.

            Full transcript: [[2026-10-04 1430 - Meeting (transcript)]]
            %% takku:end %%

            ## Personal notes


            """)
    }

    @Test("if the Summary fails the managed section shows the reason and the Transcript link")
    func summaryFailed() {
        var note = MeetingNote.initial(takkuID: takkuID, startedAt: startedAt, timeZone: rome)

        note.recordProcessing(
            takkuID: takkuID, duration: 60, language: "it", transcriptName: "T",
            summary: .failed(reason: "The provider answered with error 401: invalid key")
        )

        #expect(note.content.contains("""
            %% takku:start %%
            ⚠️ Summary not generated: The provider answered with error 401: invalid key

            Full transcript: [[T]]
            %% takku:end %%
            """))
        #expect(!note.content.contains("summary_provider"))
    }

    @Test("a failed Regeneration keeps the previous Summary")
    func failedRegenerationKeepsPreviousSummary() {
        var note = MeetingNote.initial(takkuID: takkuID, startedAt: startedAt, timeZone: rome)
        note.recordProcessing(
            takkuID: takkuID, duration: 60, language: "it", transcriptName: "T",
            summary: .written(text: "### Budget\nApproved.", template: "Notes", provider: "Mistral EU")
        )
        let previous = note.content

        note.recordRegeneration(
            takkuID: takkuID, transcriptName: "T",
            summary: .failed(reason: "The provider is offline")
        )

        #expect(note.content == previous)
    }

    @Test("a failed Processing Retry keeps the previous Summary and metadata")
    func failedProcessingRetryKeepsPreviousResult() {
        var note = MeetingNote.initial(takkuID: takkuID, startedAt: startedAt, timeZone: rome)
        note.recordProcessing(
            takkuID: takkuID, duration: 60, language: "it", transcriptName: "T",
            summary: .written(text: "### Budget\nApproved.", template: "Notes", provider: "Mistral EU")
        )
        let previous = note.content

        note.recordProcessing(
            takkuID: takkuID, duration: 120, language: "en", transcriptName: "New",
            summary: .failed(reason: "The provider is offline")
        )

        #expect(note.content == previous)
    }

    @Test("without a Summary Profile the managed section holds only the Transcript link, with no warning")
    func transcriptOnly() {
        var note = MeetingNote.initial(takkuID: takkuID, startedAt: startedAt, timeZone: rome)
        note.recordRegeneration(
            takkuID: takkuID, transcriptName: "T",
            summary: .written(text: "Old.", template: "Notes", provider: "OpenRouter")
        )

        note.recordProcessing(
            takkuID: takkuID, duration: 60, language: "it", transcriptName: "T",
            summary: .transcriptOnly
        )

        #expect(note.content.contains("""
            %% takku:start %%
            Full transcript: [[T]]
            %% takku:end %%
            """))
        #expect(!note.content.contains("template:"))
        #expect(!note.content.contains("summary_provider"))
    }

    @Test("the duration is written in minutes, with hours past 60 minutes", arguments: [
        (20.0, "1m"),
        (47.0 * 60 + 29, "47m"),
        (65.0 * 60, "1h 05m"),
    ])
    func duration(seconds: Double, expected: String) {
        var note = MeetingNote(content: "")

        note.recordProcessing(
            takkuID: takkuID, duration: seconds, language: nil, transcriptName: "T",
            summary: .failed(reason: "-")
        )

        #expect(note.content.contains("duration: \(expected)\n"))
        #expect(!note.content.contains("language:"))
    }

    @Test("if the user deleted the frontmatter, takku_id is restored")
    func takkuIDRestored() {
        var note = MeetingNote(content: "Just notes.")

        note.recordProcessing(
            takkuID: takkuID, duration: 60, language: "it", transcriptName: "T",
            summary: .failed(reason: "-")
        )

        #expect(note.takkuID == takkuID)
        #expect(note.personalNotes == "Just notes.")
    }

    @Test("if Processing fails the managed section shows the reason")
    func failureRecorded() {
        var note = MeetingNote.initial(takkuID: takkuID, startedAt: startedAt, timeZone: rome)

        note.recordFailure(takkuID: takkuID, reason: "Transcription failed: model unavailable.")

        #expect(note.content.contains("""
            %% takku:start %%
            ⚠️ Transcription failed: model unavailable.
            %% takku:end %%
            """))
    }

    @Test("a transcription failure during Retry keeps the previous result")
    func failedTranscriptionRetryKeepsPreviousResult() {
        var note = MeetingNote.initial(takkuID: takkuID, startedAt: startedAt, timeZone: rome)
        note.recordProcessing(
            takkuID: takkuID, duration: 60, language: "it", transcriptName: "T",
            summary: .written(text: "Approved.", template: "Notes", provider: "Mistral EU")
        )
        let previous = note.content

        note.recordFailure(takkuID: takkuID, reason: "Transcription failed: model unavailable.")

        #expect(note.content == previous)
    }

    @Test("Regeneration changes Summary, Template and provider but keeps duration, language and Transcript")
    func regeneration() {
        var note = MeetingNote.initial(takkuID: takkuID, startedAt: startedAt, timeZone: rome)
        note.recordProcessing(
            takkuID: takkuID, duration: 600, language: "it", transcriptName: "T",
            summary: .written(text: "Old.", template: "Notes", provider: "OpenRouter")
        )

        note.recordRegeneration(
            takkuID: takkuID, transcriptName: "T",
            summary: .written(text: "### Retro\nNew.", template: "Retro", provider: "Mistral EU")
        )

        #expect(note.content.contains("duration: 10m\n"))
        #expect(note.content.contains("language: it\n"))
        #expect(note.content.contains("template: Retro\n"))
        #expect(note.content.contains("summary_provider: Mistral EU\n"))
        #expect(note.content.contains("%% takku:start %%\n### Retro\nNew.\n\nFull transcript: [[T]]\n%% takku:end %%"))
        #expect(!note.content.contains("Old."))
    }

    @Test("another calendar event's participants replace the list, the user's keys and notes stay")
    func replaceParticipants() {
        var note = MeetingNote(content: """
            ---
            takku_id: 6F1C2A00-0000-4000-8000-000000000001
            date: 2026-10-04T14:30
            tags: [meeting]
            participants:
              - "Wrong Person"
            - "Unindented"
            speakers:
              - Speaker 1 = Mario Rossi
            ---
            Body.

            """)

        note.replaceParticipants(with: ["Mario Rossi", "Anna \"Nina\" Bianchi"])
        #expect(note.participants == ["Mario Rossi", "Anna \"Nina\" Bianchi"])
        #expect(note.speakerNames == [1: "Mario Rossi"])
        #expect(note.content.hasSuffix("---\nBody.\n"))

        note.replaceParticipants(with: [])
        #expect(!note.content.contains("participants:"))
        #expect(note.speakerNames == [1: "Mario Rossi"])

        note.replaceParticipants(with: ["Mario Rossi"])
        #expect(note.content.contains("speakers:\n  - Speaker 1 = Mario Rossi\nparticipants:\n  - \"Mario Rossi\"\n---"))
    }

    @Test("Speaker names can be edited as a list and empty names are omitted")
    func replaceSpeakerNames() {
        var note = MeetingNote.initial(takkuID: takkuID, startedAt: startedAt, timeZone: rome)

        note.replaceSpeakerNames(with: [2: " Anna Bianchi ", 1: "Mario Rossi", 3: " "])
        #expect(note.speakerNames == [1: "Mario Rossi", 2: "Anna Bianchi"])
        #expect(note.content.contains("speakers:\n  - Speaker 1 = Mario Rossi\n  - Speaker 2 = Anna Bianchi\n---"))

        note.replaceSpeakerNames(with: [2: "Anna Verdi"])
        #expect(note.speakerNames == [2: "Anna Verdi"])
        #expect(!note.content.contains("Mario Rossi"))

        note.replaceSpeakerNames(with: [:])
        #expect(note.speakerNames.isEmpty)
        #expect(!note.content.contains("speakers:"))
    }

    @Test("participants written at the start read back as they were")
    func initialParticipants() {
        let note = MeetingNote.initial(takkuID: takkuID, startedAt: startedAt, participants: ["Mario Rossi"], timeZone: rome)
        #expect(note.content.contains("tags: [meeting]\nparticipants:\n  - \"Mario Rossi\"\n---"))
        #expect(note.participants == ["Mario Rossi"])
    }
}
