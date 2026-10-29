import Foundation
import Testing
import TakkuCore

@Suite("Speaker samples for naming Speakers")
struct SpeakerSampleTests {
    private func transcript(_ body: String) -> Transcript {
        Transcript.parse(vaultFile: "---\nlanguage: it\n---\n" + body).transcript
    }

    @Test("every Speaker gets their paragraphs, the longest first, cut where someone else starts")
    func samples() {
        let samples = SpeakerSample.samples(in: transcript("""
            **[00:00] Speaker 1:** Ciao a tutti.
            **[00:03] Me:** Ciao.
            **[00:05] Mario Rossi (Speaker 2):** Allora oggi parliamo della parte di retrieval e di come la teniamo separata dal resto.
            **[01:10] Speaker 1:** Va bene, per me la parte di retrieval va tenuta separata.
            **[01:14] Speaker 2:** Sì.
            """))

        #expect(samples[1] == [
            SpeakerSample(speaker: 1, start: 70, duration: 4, quote: "Va bene, per me la parte di retrieval va tenuta separata."),
            SpeakerSample(speaker: 1, start: 0, duration: 3, quote: "Ciao a tutti."),
        ])
        #expect(samples[2]?.map(\.start) == [5, 74])
        #expect(samples[2]?.first?.duration == SpeakerSample.maxDuration)
    }

    @Test("Me and Others not told apart have no samples")
    func onlySpeakers() {
        let samples = SpeakerSample.samples(in: transcript("""
            **[00:00] Me:** Buongiorno.
            **[00:04] Others:** Buongiorno a te.
            """))

        #expect(samples.isEmpty)
    }

    @Test("at most `limit` samples per Speaker")
    func limit() {
        let samples = SpeakerSample.samples(in: transcript("""
            **[00:00] Speaker 1:** Uno.
            **[00:10] Me:** Due.
            **[00:20] Speaker 1:** Tre tre.
            **[00:30] Me:** Quattro.
            **[00:40] Speaker 1:** Cinque cinque cinque.
            """), limit: 2)

        #expect(samples[1]?.map(\.start) == [40, 20])
    }

    @Test("the last paragraph plays for the maximum; one cut very short still plays a little")
    func durations() {
        let samples = SpeakerSample.samples(in: transcript("""
            **[00:00] Speaker 1:** Ok.
            **[00:00] Speaker 2:** No, aspetta un attimo.
            """))

        #expect(samples[1]?.first?.duration == SpeakerSample.minDuration)
        #expect(samples[2]?.first?.duration == SpeakerSample.maxDuration)
    }

    @Test("the quote keeps the first words, without the Mark")
    func quote() {
        let samples = SpeakerSample.samples(in: transcript("""
            **[00:00] Speaker 1:** ⭐ uno due tre quattro cinque sei sette otto nove dieci undici dodici tredici quattordici
            """))

        #expect(samples[1]?.first?.quote == "uno due tre quattro cinque sei sette otto nove dieci undici dodici…")
    }

    @Test("a Meeting time is found in the Segment of its Track that covers it")
    func audioLocation() {
        let recording = Recording(
            meetingID: UUID(), startedAt: Date(), endedAt: Date(),
            segments: [
                Segment(track: .me, index: 0, start: 0),
                Segment(track: .others, index: 0, start: 2),
                Segment(track: .others, index: 1, start: 302),
            ]
        )

        #expect(recording.segment(of: .others, at: 350)?.segment == Segment(track: .others, index: 1, start: 302))
        #expect(recording.segment(of: .others, at: 350)?.offset == 48)
        #expect(recording.segment(of: .others, at: 10)?.offset == 8)
        #expect(recording.segment(of: .others, at: 1) == nil)
    }
}
