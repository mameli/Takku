import Testing
import TakkuCore

@Suite("Recognising Parakeet's sentences in a language the Meeting is not in")
struct OtherLanguageTests {
    @Test("a sentence in another language is dropped", arguments: [
        "Aber ich glaube, ich muss mit der Punkt mit der Gegenstände ab 1013.",
        "Det här kommt blockad om.",
        "Ну, что ты так должен?",
        "Maar dat is echt een beetje voor.",
    ])
    func otherLanguage(text: String) {
        #expect(isInAnotherLanguage(text, meetingLanguages: ["it", "en"]))
    }

    @Test("a sentence in a Meeting language is kept", arguments: [
        "Ciao, scusatemi davvero tanto.",
        "Let me share my screen now.",
        "Vai continua Gabriele.",
        "Io le vederei onestamente, no, no, no.",
        "O altra idea?",
    ])
    func meetingLanguage(text: String) {
        #expect(!isInAnotherLanguage(text, meetingLanguages: ["it", "en"]))
    }

    @Test("fillers do not make English look like another language", arguments: [
        "Um so um I mentioned think aloud.",
        "Uh whereas uh the implementers um actually um engaged uh and it's a very good point.",
        "okay so um",
    ])
    func fillers(text: String) {
        #expect(!isInAnotherLanguage(text, meetingLanguages: ["it", "en"]))
    }

    @Test("a single word is kept: too little to tell the language")
    func singleWord() {
        #expect(!isInAnotherLanguage("Okej.", meetingLanguages: ["it", "en"]))
        #expect(!isInAnotherLanguage("Um, andere.", meetingLanguages: ["it", "en"]))
    }

    @Test("a language ticked for the Meeting is kept")
    func tickedLanguage() {
        #expect(!isInAnotherLanguage("Aber ich glaube, ich muss mit der Punkt mit der Gegenstände ab 1013.", meetingLanguages: ["it", "de"]))
    }

    @Test("with only Italian ticked an English sentence is dropped")
    func onlyItalian() {
        #expect(isInAnotherLanguage("Let me share my screen now.", meetingLanguages: ["it"]))
    }

    static let spanish = [
        "Buenos días a todos, gracias por conectaros tan temprano.",
        "Hoy quería repasar el estado del proyecto y las próximas entregas.",
        "El equipo de diseño terminó las pantallas nuevas la semana pasada.",
        "Todavía nos falta revisar los textos con el cliente antes del viernes.",
        "Si os parece bien, Lucía se encarga de preparar la presentación.",
        "Vale, perfecto, entonces nos vemos el jueves a la misma hora.",
    ]

    @Test("a Segment spoken in a language not ticked is kept, in that language")
    func untickedMeeting() {
        #expect(untickedLanguage(dropped: Self.spanish, kept: ["Ok."]) == "es")
    }

    @Test("a few made-up sentences, or ones jumping between languages, stay dropped")
    func madeUp() {
        #expect(untickedLanguage(dropped: Array(Self.spanish.prefix(2)), kept: []) == nil)
        let mixed = [
            "Aber ich glaube, ich muss mit der Punkt mit der Gegenstände ab 1013.",
            "Det här kommt blockad om, och vi ser vad som händer sen med det här.",
            "Ну, что ты так должен? Я не знаю, что ты хочешь сказать мне сейчас.",
            "Maar dat is echt een beetje voor, ik weet niet wat we moeten doen.",
            "To je naozaj zvláštne, neviem čo s tým máme robiť v tomto prípade.",
        ]
        #expect(untickedLanguage(dropped: mixed, kept: []) == nil)
    }

    @Test("a stretch in another language inside a longer meeting stays dropped")
    func minority() {
        let italian = Array(repeating: "Allora ragazzi, partiamo dal punto più urgente e poi vediamo il resto della lista insieme.", count: 8)
        #expect(untickedLanguage(dropped: Self.spanish, kept: italian) == nil)
    }
}
