import Foundation
import Testing
import TakkuCore

@Suite("Merging Tracks into the Transcript")
struct TranscriptTests {
    let takkuID = UUID(uuidString: "6F1C2A00-0000-4000-8000-000000000001")!

    @Test("Utterances from the two Tracks interleave in time order")
    func interleavesByStart() {
        let transcript = Transcript(utterances: [
            Utterance(track: .me, start: 12, end: 15, text: "Yes, on the first point."),
            Utterance(track: .others, start: 0, end: 10, text: "Good morning everyone."),
            Utterance(track: .others, start: 20, end: 25, text: "Great, let's move on."),
        ])

        #expect(transcript.paragraphs == [
            Paragraph(track: .others, start: 0, text: "Good morning everyone."),
            Paragraph(track: .me, start: 12, text: "Yes, on the first point."),
            Paragraph(track: .others, start: 20, text: "Great, let's move on."),
        ])
    }

    @Test("consecutive Utterances of the same Track become one paragraph with the first one's start")
    func mergesConsecutiveSameTrack() {
        let transcript = Transcript(utterances: [
            Utterance(track: .others, start: 0, end: 4, text: "Good morning everyone."),
            Utterance(track: .others, start: 5, end: 9, text: "Let's start with the budget."),
            Utterance(track: .me, start: 10, end: 12, text: "Sure."),
        ])

        #expect(transcript.paragraphs == [
            Paragraph(track: .others, start: 0, text: "Good morning everyone. Let's start with the budget."),
            Paragraph(track: .me, start: 10, text: "Sure."),
        ])
    }

    @Test("after a pause longer than 30 seconds the same Track starts a new paragraph")
    func longPauseStartsNewParagraph() {
        let transcript = Transcript(utterances: [
            Utterance(track: .others, start: 0, end: 20, text: "First part."),
            Utterance(track: .others, start: 45, end: 50, text: "Still close."),
            Utterance(track: .others, start: 420, end: 430, text: "Five minutes later."),
        ])

        #expect(transcript.paragraphs == [
            Paragraph(track: .others, start: 0, text: "First part. Still close."),
            Paragraph(track: .others, start: 420, text: "Five minutes later."),
        ])
    }

    @Test("Utterances made only of annotations or whitespace are dropped, the rest is trimmed")
    func dropsAnnotations() {
        let transcript = Transcript(utterances: [
            Utterance(track: .others, start: 0, end: 4, text: "  Good morning everyone. "),
            Utterance(track: .me, start: 5, end: 30, text: "[BLANK_AUDIO]"),
            Utterance(track: .me, start: 31, end: 60, text: " (Tolken pratar i en annan länk)"),
            Utterance(track: .me, start: 61, end: 62, text: "   "),
            Utterance(track: .others, start: 63, end: 66, text: "[Music]"),
            Utterance(track: .others, start: 67, end: 70, text: "Let's start with the budget."),
        ])

        #expect(transcript.paragraphs == [
            Paragraph(track: .others, start: 0, text: "Good morning everyone."),
            Paragraph(track: .others, start: 67, text: "Let's start with the budget."),
        ])
    }

    @Test("a paragraph stays under 60 seconds: past that the same Track starts again with a new timestamp")
    func longMonologueIsSplit() {
        let transcript = Transcript(utterances: [
            Utterance(track: .others, start: 0, end: 25, text: "One."),
            Utterance(track: .others, start: 26, end: 50, text: "Two."),
            Utterance(track: .others, start: 51, end: 75, text: "Three."),
            Utterance(track: .others, start: 76, end: 100, text: "Four."),
        ])

        #expect(transcript.paragraphs == [
            Paragraph(track: .others, start: 0, text: "One. Two. Three."),
            Paragraph(track: .others, start: 76, text: "Four."),
        ])
    }

    @Test("the Markdown puts timestamp and label in bold, one paragraph per block")
    func markdown() {
        let transcript = Transcript(utterances: [
            Utterance(track: .others, start: 0, end: 4, text: "Good morning everyone."),
            Utterance(track: .me, start: 42.7, end: 45, text: "Yes, on the first point."),
            Utterance(track: .others, start: 3723, end: 3730, text: "Let's wrap up."),
        ])

        #expect(transcript.markdown == """
            **[00:00] Others:** Good morning everyone.

            **[00:42] Me:** Yes, on the first point.

            **[1:02:03] Others:** Let's wrap up.

            """)
    }

    @Test("the Transcript file in the Vault has frontmatter with takku_id, link to the Meeting note and language")
    func vaultFile() {
        let transcript = Transcript(utterances: [
            Utterance(track: .others, start: 0, end: 4, text: "Good morning everyone."),
        ])

        let file = transcript.vaultFile(takkuID: takkuID, meetingNoteName: "2026-10-04 1430 - Meeting", language: "it")

        #expect(file == """
            ---
            takku_id: 6F1C2A00-0000-4000-8000-000000000001
            meeting: "[[2026-10-04 1430 - Meeting]]"
            language: it
            ---
            **[00:00] Others:** Good morning everyone.

            """)
    }

    @Test("without speech the language is left out of the frontmatter")
    func vaultFileWithoutLanguage() {
        let file = Transcript(utterances: []).vaultFile(
            takkuID: takkuID, meetingNoteName: "2026-10-04 1430 - Meeting", language: nil
        )

        #expect(file == """
            ---
            takku_id: 6F1C2A00-0000-4000-8000-000000000001
            meeting: "[[2026-10-04 1430 - Meeting]]"
            ---

            """)
    }

    @Test("the Transcript file in the Vault reads back with paragraphs, times and language")
    func parseVaultFile() {
        let original = Transcript(utterances: [
            Utterance(track: .others, start: 0, end: 4, text: "Good morning everyone."),
            Utterance(track: .me, start: 42.7, end: 45, text: "Yes, on the first point."),
            Utterance(track: .others, start: 3723, end: 3730, text: "Let's wrap up."),
        ])
        let file = original.vaultFile(takkuID: takkuID, meetingNoteName: "2026-10-04 1430 - Meeting", language: "en")

        let (parsed, language) = Transcript.parse(vaultFile: file)

        #expect(language == "en")
        #expect(parsed.paragraphs == [
            Paragraph(track: .others, start: 0, text: "Good morning everyone."),
            Paragraph(track: .me, start: 42, text: "Yes, on the first point."),
            Paragraph(track: .others, start: 3723, text: "Let's wrap up."),
        ])
    }

    @Test("lines added or fixed by hand stay in the paragraph they belong to")
    func parseEditedVaultFile() {
        let file = """
            ---
            takku_id: 1
            ---
            **[00:00] Others:** The budget is 40 thousand euros.
            (fixed by hand: 45 thousand)

            **[00:12] Me:** Fine.
            """

        let (parsed, language) = Transcript.parse(vaultFile: file)

        #expect(language == nil)
        #expect(parsed.paragraphs == [
            Paragraph(track: .others, start: 0, text: "The budget is 40 thousand euros. (fixed by hand: 45 thousand)"),
            Paragraph(track: .me, start: 12, text: "Fine."),
        ])
    }

    @Test("the Speakers without a name are those that speak and are not named in the note, by number")
    func unnamedSpeakers() {
        let transcript = Transcript(utterances: [
            Utterance(track: .others, start: 0, end: 2, text: "Ciao.", speaker: 3),
            Utterance(track: .me, start: 5, end: 7, text: "Ciao a tutti."),
            Utterance(track: .others, start: 9, end: 11, text: "Partiamo.", speaker: 1),
            Utterance(track: .others, start: 12, end: 13, text: "Ok.", speaker: 2),
            Utterance(track: .others, start: 15, end: 16, text: "Bene.", speaker: 1),
            Utterance(track: .others, start: 20, end: 21, text: "Senza voce."),
        ])

        #expect(transcript.unnamedSpeakers(names: [:]) == [1, 2, 3])
        #expect(transcript.unnamedSpeakers(names: [2: "Mario Rossi", 7: "Luca"]) == [1, 3])
        #expect(transcript.unnamedSpeakers(names: [1: "A", 2: "B", 3: "C"]).isEmpty)
        #expect(Transcript(utterances: [Utterance(track: .me, start: 0, end: 1, text: "Solo io.")]).unnamedSpeakers(names: [:]).isEmpty)
    }

    @Test("a time with more digits than any Recording has is read as text, not as a time")
    func absurdTime() {
        let file = "---\ntakku_id: 1\n---\n**[00:05] Me:** hello\n**[99999999999999999999999:00:00] Speaker 1:** edited\n"
        let (parsed, _) = Transcript.parse(vaultFile: file)

        #expect(parsed.paragraphs.count == 1)
        #expect(parsed.paragraphs[0].start == 5)
        #expect(parsed.paragraphs[0].text.contains("edited"))
        #expect(parsed.markdown.contains("[00:05]"))
    }
}
