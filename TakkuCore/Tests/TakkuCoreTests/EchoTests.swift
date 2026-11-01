import Testing
import TakkuCore

@Suite("Removing the others' voice leaked into the microphone")
struct EchoTests {
    let others = [
        Utterance(track: .others, start: 0, end: 6, text: " Una cosa che capisce pure l'uomo della strada,"),
        Utterance(track: .others, start: 6, end: 11, text: " cioè non è che serve essere un esperto, la macchina ti parla."),
        Utterance(track: .others, start: 60, end: 64, text: " Passiamo al budget del trimestre."),
    ]

    @Test("Me sentences repeating what the others say at the same moment are echo")
    func echoRemoved() {
        let me = [
            Utterance(track: .me, start: 3.3, end: 4.3, text: " strada"),
            Utterance(track: .me, start: 4.3, end: 6.9, text: " non è che serve"),
            Utterance(track: .me, start: 6.9, end: 8.3, text: " essere un esperto"),
        ]

        #expect(removingEcho(others + me) == others)
    }

    @Test("what I say while the others talk stays")
    func overlappingSpeechKept() {
        let me = [Utterance(track: .me, start: 5, end: 8, text: " Scusa, ti interrompo un attimo sulla macchina.")]

        #expect(removingEcho(others + me) == others + me)
    }

    @Test("repeating the others' words later, e.g. quoting them, is not echo")
    func laterQuoteKept() {
        let me = [Utterance(track: .me, start: 120, end: 123, text: " Non è che serve essere un esperto.")]

        #expect(removingEcho(others + me) == others + me)
    }

    @Test("a short reply is kept even if the others say the same word at the same time")
    func shortReplyKept() {
        let me = [Utterance(track: .me, start: 61, end: 61.5, text: " Budget.")]

        #expect(removingEcho(others + me) == others + me)
    }

    @Test("Me sentences 25 dB fainter than my loudest one are the others' voice left by echo cancellation")
    func residueRemoved() {
        let mine = Utterance(track: .me, start: 2, end: 5, text: "Tutto bene, partiamo.")
        let quietReply = Utterance(track: .me, start: 20, end: 21, text: "Mm-hmm.")
        let residue = Utterance(track: .me, start: 61, end: 62, text: "The five.")
        let measured: [(utterance: Utterance, level: Double?)] = [
            (mine, -12), (quietReply, -36.9), (residue, -41), (others[2], nil),
        ]

        #expect(removingEchoResidue(measured) == [mine, quietReply, others[2]])
    }

    @Test("without a level the sentence stays, and with no Me level nothing is removed")
    func unknownLevelsKept() {
        let me = Utterance(track: .me, start: 2, end: 5, text: "Tutto bene.")
        let unmeasured = Utterance(track: .me, start: 6, end: 7, text: "Ok.")

        #expect(removingEchoResidue([(me, -12), (unmeasured, nil)]) == [me, unmeasured])
        #expect(removingEchoResidue([(unmeasured, nil), (others[0], nil)]) == [unmeasured, others[0]])
    }

    @Test("the level of a stretch of audio is the RMS of its loudest tenth of a second, in dBFS")
    func peakLevelOfAudio() {
        let sampleRate = 16_000.0
        let silence = [Float](repeating: 0, count: 16_000)
        let loud = [Float](repeating: 0.1, count: 1_600)

        #expect(abs(peakLevel(of: (silence + loud + silence)[...], sampleRate: sampleRate) - (-20)) < 0.01)
        #expect(peakLevel(of: silence[...], sampleRate: sampleRate) < -100)
        #expect(abs(peakLevel(of: loud[..<400], sampleRate: sampleRate) - (-20)) < 0.01)
    }

    @Test("a degraded copy of the others' words is echo too")
    func misspelledEchoRemoved() {
        let me = [Utterance(track: .me, start: 6.5, end: 10, text: " cioè non è che servi essere un esperta, la macchina di parla")]

        #expect(removingEcho(others + me) == others)
    }

    /// 12 seconds of the others with their voice coming back from the speakers into my microphone,
    /// and my own voice from 5 to 8 seconds.
    func speakerSignal() -> EchoSignal {
        let othersAudio = EchoSignalTests.speech(12, seed: 11)
        var meAudio = EchoSignalTests.bleed(othersAudio, delay: 60, gain: 0.08)
        EchoSignalTests.adding(EchoSignalTests.speech(3, seed: 29), at: 5, gain: 0.9, to: &meAudio)
        return EchoSignalTests.signal(othersAudio, meAudio)
    }

    @Test("with the signal, bleed is echo even when its words came out different")
    func bleedRemoved() {
        let me = [Utterance(track: .me, start: 1, end: 4.5, text: " Una casa che capisce più lui della strada")]

        #expect(removingEcho(others + me, signal: speakerSignal()) == others)
    }

    @Test("with the signal, my voice over the others stays even when the words match")
    func localKept() {
        let me = [Utterance(track: .me, start: 5, end: 8, text: " non è che serve essere un esperto")]

        #expect(removingEcho(others + me, signal: speakerSignal()) == others + me)
    }

    @Test("in a run of echo, my own sentence shown local by the signal stays")
    func localSentenceInEchoRun() {
        let bleed = Utterance(track: .me, start: 1, end: 4.5, text: " una cosa che capisce pure l'uomo della strada")
        let mine = Utterance(track: .me, start: 5, end: 8, text: " Sì, però dobbiamo decidere il budget.")

        #expect(removingEcho(others + [bleed, mine], signal: speakerSignal()) == others + [mine])
    }
}
