import Testing
import TakkuCore

@Suite("Recognising Whisper's made-up sentences")
struct HallucinationTests {
    @Test("a stock subtitle sentence on a short burst of sound is made up", arguments: [
        " Grazie.", "Grazie a tutti!", "Sottotitoli creati dalla comunità Amara.org", " Thank you.", "Thanks for watching!",
        "Vielen Dank!", "Merci d'avoir regardé.", "¡Muchas gracias!",
    ])
    func stockSentenceOnShortSound(text: String) {
        #expect(isLikelyHallucination([text], speechDuration: 1.5))
    }

    @Test("the same sentence is kept when it comes from a longer stretch of speech")
    func longSpeech() {
        #expect(!isLikelyHallucination([" Grazie."], speechDuration: 6))
    }

    @Test("a real short reply is kept")
    func realReply() {
        #expect(!isLikelyHallucination([" Sì, va bene."], speechDuration: 1.5))
        #expect(!isLikelyHallucination([" Grazie.", " Ci sentiamo domani."], speechDuration: 2.5))
    }
}
