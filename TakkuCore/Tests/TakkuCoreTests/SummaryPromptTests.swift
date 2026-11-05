import Testing
@testable import TakkuCore

@Suite("Summary prompt")
struct SummaryPromptTests {
    let template = Template(fileName: "Notes", content: "Be brief.\n\n### Topics\n### Next steps")
    let transcript = Transcript(utterances: [
        Utterance(track: .others, start: 0, end: 4, text: "The budget is approved."),
        Utterance(track: .me, start: 5, end: 8, text: "I'll send the offer on Friday."),
    ])

    @Test("the user message holds Template, personal notes and Transcript, in this order")
    func userMessage() {
        let prompt = SummaryPrompt(template: template, personalNotes: "- budget!", transcript: transcript, meetingLanguage: "it")

        let messages = prompt.singleRequest()

        #expect(messages.map(\.role) == [.system, .user])
        #expect(messages[1].content == """
            # Template
            Be brief.

            ### Topics
            ### Next steps

            # Personal notes
            - budget!

            # Transcript
            **[00:00] Others:** The budget is approved.

            **[00:05] Me:** I'll send the offer on Friday.
            """)
    }

    @Test("the rules live in the system message")
    func systemRules() {
        let system = SummaryPrompt(template: template, personalNotes: "", transcript: transcript, meetingLanguage: "it")
            .singleRequest()[0].content

        #expect(system.contains("Write the summary in Italian"))
        #expect(system.contains("Do not invent"))
        #expect(system.contains("Follow the structure and instructions of the Template"))
        // The action format is the Template's; this one applies only when the Template says nothing.
        #expect(system.contains("in the format the Template asks for"))
        #expect(system.contains("- [ ] who: what (when)"))
        #expect(system.contains("\"Me\""))
        #expect(system.contains("personal notes"))
    }

    @Test("Me is written with the user's name, also in the partial requests of a long Meeting")
    func meByName() {
        let prompt = SummaryPrompt(
            template: template, personalNotes: "", transcript: transcript, meetingLanguage: "it", userName: " Mario Rossi "
        )

        #expect(prompt.singleRequest()[0].content.contains("\"Me\" is Mario Rossi, the person who took the personal notes"))
        #expect(prompt.singleRequest()[0].content.contains("never as \"Me\""))
        #expect(prompt.partialRequests(maxContextTokens: 8_192)[0][0].content.contains("\"Me\" is Mario Rossi"))
    }

    @Test("without the user's name the model still never writes Me")
    func meWithoutName() {
        let system = SummaryPrompt(template: template, personalNotes: "", transcript: transcript, meetingLanguage: "it", userName: "")
            .singleRequest()[0].content

        #expect(system.contains("Never write \"Me\" in the summary"))
    }

    @Test("the model names a Speaker from what is said, writes the number only on an action, and leaves no placeholder for who")
    func speakers() {
        let system = SummaryPrompt(template: template, personalNotes: "", transcript: transcript, meetingLanguage: "it")
            .singleRequest()[0].content

        #expect(system.contains("\"Speaker 1\", \"Speaker 2\"…, told apart by their voice"))
        #expect(system.contains("the one they introduce themselves with, or the one they answer to when called"))
        #expect(system.contains("write \"Speaker N\" only as who takes on an action"))
        #expect(system.contains("write the bullet without a subject (e.g. \"It is proposed to…\" instead of \"Speaker 2 proposes…\")"))
        #expect(system.contains("never \"Speaker N\" in a heading or in the other bullets"))
        #expect(system.contains("Leave out who or when if they are not clear, with nothing in their place"))
    }

    @Test("Others gets a name only where the Transcript says who is speaking, also in the partial requests")
    func othersUnnamed() {
        let prompt = SummaryPrompt(template: template, personalNotes: "", transcript: transcript, meetingLanguage: "it")
        let rule = "\"Others\" is anyone not told apart, often several people: give it a name only in a passage where the Transcript itself says who is speaking"

        #expect(prompt.singleRequest()[0].content.contains(rule))
        #expect(prompt.partialRequests(maxContextTokens: 8_192)[0][0].content.contains(rule))
    }

    @Test("who takes on an action comes from the Transcript, not from the notes or the invitation")
    func actionOwner() {
        let system = SummaryPrompt(template: template, personalNotes: "", transcript: transcript, meetingLanguage: "it")
            .singleRequest()[0].content

        let invited = SummaryPrompt(
            template: template, personalNotes: "", transcript: transcript, meetingLanguage: "it", participants: ["Anna Bianchi"]
        ).singleRequest()[0].content

        #expect(system.contains("Write who only when the Transcript makes clear who took the action on: a name in the personal notes is not enough."))
        #expect(invited.contains("a name in the personal notes or among the invited participants is not enough"))
    }

    @Test("an action is something taken on in the Meeting, and with none there is no line saying so")
    func actions() {
        let system = SummaryPrompt(template: template, personalNotes: "", transcript: transcript, meetingLanguage: "it")
            .singleRequest()[0].content

        #expect(system.contains("An action is something someone took on in this meeting"))
        #expect(system.contains("work in progress that someone reports, waiting for others or attending a meeting already planned are not actions"))
        #expect(system.contains("With no actions, write none and no line saying there are none"))
    }

    @Test("material pasted in the personal notes is context, not what was said, also in the partial requests")
    func pastedNotes() {
        let prompt = SummaryPrompt(template: template, personalNotes: "Ciao Mario, …", transcript: transcript, meetingLanguage: "it")
        let rule = "such as an email or a list of people: use it to understand the meeting, but it is not what was said or decided in it, and a name in the notes does not say who spoke"

        #expect(prompt.singleRequest()[0].content.contains(rule))
        #expect(prompt.partialRequests(maxContextTokens: 8_192)[0][0].content.contains(rule))
    }

    @Test("passages that make no sense are left out, not copied nor flagged as unclear, also in the partial requests")
    func nonsense() {
        let prompt = SummaryPrompt(template: template, personalNotes: "", transcript: transcript, meetingLanguage: "it")
        let rule = "Leave out passages that make no sense, such as a misheard figure or date, instead of copying them, and without saying so: never a bullet saying that a term or a passage is unclear."

        #expect(prompt.singleRequest()[0].content.contains("Do not invent: use only what is in the Transcript and in the personal notes. " + rule))
        #expect(prompt.partialRequests(maxContextTokens: 8_192)[0][0].content.contains(rule))
    }

    @Test("every point must cite the time of the Transcript it comes from, and the model knows the times are removed")
    func citedTimes() {
        let system = SummaryPrompt(template: template, personalNotes: "", transcript: transcript, meetingLanguage: "it")
            .singleRequest()[0].content

        #expect(system.contains("end it with the time of the Transcript passage it comes from"))
        #expect(system.contains("`[12:34]`"))
        #expect(system.contains("Leave out what you cannot point to"))
        #expect(system.contains("Takku removes the times"))
    }

    @Test("a Transcript cut mid-sentence is summarised only up to where it stops")
    func truncatedTranscript() {
        let system = SummaryPrompt(template: template, personalNotes: "", transcript: transcript, meetingLanguage: "it")
            .singleRequest()[0].content

        #expect(system.contains("The Transcript may stop mid-sentence"))
        #expect(system.contains("do not complete talks, lists, steps or results that are announced but not reached"))
    }

    let vocabulary = Vocabulary(fileContent: """
        - Takku = abtakku, takku | our app for recording meetings
        - Scaleway = scale uai
        - Mameli
        """)

    @Test("the Vocabulary goes into the system message: a listed variant is always the term, other words are corrected only when certain")
    func vocabularyInSystemMessage() {
        let messages = SummaryPrompt(
            template: template, personalNotes: "", transcript: transcript, meetingLanguage: "it", vocabulary: vocabulary
        ).singleRequest()

        let system = messages[0].content
        #expect(system.contains("- Takku: our app for recording meetings (may be written as \"abtakku\", \"takku\")"))
        #expect(system.contains("- Scaleway (may be written as \"scale uai\")"))
        #expect(system.contains("\n- Mameli\n"))
        #expect(system.contains("automatic speech recognition"))
        #expect(system.contains("A word written as one of the variants listed above is that term: always write the term."))
        #expect(system.contains("For other words use the Vocabulary and the context to write them right, but correct a word only when you are sure"))
        #expect(system.contains("Do not bring in a term that nobody said."))
        // The Vocabulary is not part of what the user message carries.
        #expect(!messages[1].content.contains("Scaleway"))
    }

    @Test("only the first three variants of a term go into the system message: they show how it is misheard, the replacement uses them all")
    func fewVariantsInSystemMessage() {
        let vocabulary = Vocabulary(fileContent: "- Witboost = with boost, wit boost, Witbust, Weatboost, WePost")
        let system = SummaryPrompt(
            template: template, personalNotes: "", transcript: transcript, meetingLanguage: "it", vocabulary: vocabulary
        ).singleRequest()[0].content

        #expect(system.contains("- Witboost (may be written as \"with boost\", \"wit boost\", \"Witbust\")\n"))
        #expect(!system.contains("Weatboost"))
        #expect(!system.contains("WePost"))
    }

    @Test("a Transcript read back from the Vault gets the variants added to the Vocabulary since, in what the model reads only")
    func variantsReplacedInTranscriptReadBack() {
        let vaultFile = """
            ---
            takku_id: 6F1C2B9E-0000-0000-0000-000000000000
            ---
            **[00:05] Speaker 1:** Il deploy di WePost è pronto.

            **[00:40] Me:** ⭐ Bene, with boost anche in staging.
            """
        let (readBack, _) = Transcript.parse(vaultFile: vaultFile)
        let vocabulary = Vocabulary(fileContent: "- Witboost = with boost, wit boost, Witbust, Weatboost, WePost")
        let prompt = SummaryPrompt(template: template, personalNotes: "", transcript: readBack, meetingLanguage: "it", vocabulary: vocabulary)

        #expect(prompt.singleRequest()[1].content.contains("**[00:05] Speaker 1:** Il deploy di Witboost è pronto."))
        #expect(prompt.partialRequests(maxContextTokens: 8_192)[0][1].content.contains("Il deploy di Witboost è pronto."))
        #expect(prompt.singleRequest()[1].content.contains("**[00:40] Me:** ⭐ Bene, Witboost anche in staging."))
        // The Transcript in the Vault is the user's: only the request changes.
        #expect(readBack.paragraphs[0].text == "Il deploy di WePost è pronto.")
    }

    @Test("without a Vocabulary the system message has no trace of it")
    func noVocabulary() {
        let system = SummaryPrompt(template: template, personalNotes: "", transcript: transcript, meetingLanguage: "it")
            .singleRequest()[0].content

        #expect(!system.contains("Vocabulary"))
        #expect(system.hasSuffix("without preambles."))
    }

    @Test("Summary language: the Template's, else the Meeting's, else Italian; any language can be named", arguments: [
        ("en", "it", "Write the summary in English"),
        (nil, "en", "Write the summary in English"),
        (nil, "it", "Write the summary in Italian"),
        (nil, nil, "Write the summary in Italian"),
        ("fr", "en", "Write the summary in French"),
        ("de", nil, "Write the summary in German"),
    ] as [(String?, String?, String)])
    func language(templateLanguage: String?, meetingLanguage: String?, rule: String) {
        let header = templateLanguage.map { "---\nsummary_language: \($0)\n---\n" } ?? ""
        let template = Template(fileName: "T", content: header + "### Topics")

        let system = SummaryPrompt(template: template, personalNotes: "", transcript: transcript, meetingLanguage: meetingLanguage)
            .singleRequest()[0].content

        #expect(system.contains(rule))
    }

    @Test("without personal notes the model is told so explicitly")
    func noPersonalNotes() {
        let user = SummaryPrompt(template: template, personalNotes: "", transcript: transcript, meetingLanguage: "it")
            .singleRequest()[1].content

        #expect(user.contains("# Personal notes\n(none)\n"))
    }
}

@Suite("Summary prompt: names, participants and Marks")
struct SummaryPromptPeopleTests {
    let template = Template(fileName: "Notes", content: "Be brief.")
    let transcript = Transcript(utterances: [
        Utterance(track: .others, start: 0, end: 4, text: "The budget is approved.", speaker: 1),
        Utterance(track: .me, start: 5, end: 8, text: "I'll send the offer on Friday."),
    ])

    @Test("Speakers the user named are certain for the model; without names the rule is not there")
    func namedSpeakers() {
        let named = SummaryPrompt(
            template: template, personalNotes: "", transcript: transcript.naming([1: "Anna Bianchi"]), meetingLanguage: "it"
        )
        let unnamed = SummaryPrompt(template: template, personalNotes: "", transcript: transcript, meetingLanguage: "it")

        #expect(named.singleRequest()[0].content.contains("\"Name (Speaker N)\" in the Transcript is a name the user gave"))
        #expect(named.partialRequests(maxContextTokens: 8_192)[0][0].content.contains("\"Name (Speaker N)\""))
        #expect(named.singleRequest()[1].content.contains("**[00:00] Anna Bianchi (Speaker 1):**"))
        #expect(!unnamed.singleRequest()[0].content.contains("Name (Speaker N)"))
    }

    @Test("invited participants go in the user message after the notes, with the rule not to guess from them")
    func participants() {
        let prompt = SummaryPrompt(
            template: template, personalNotes: "- budget", transcript: transcript, meetingLanguage: "it",
            participants: ["Anna Bianchi", "Luca Verdi"]
        )

        #expect(prompt.singleRequest()[1].content.contains("""
            # Personal notes
            - budget

            # Invited participants
            - Anna Bianchi
            - Luca Verdi

            # Transcript
            """))
        #expect(prompt.singleRequest()[0].content.contains("not who spoke"))
        #expect(prompt.singleRequest()[0].content.contains("exactly one invited participant and one Speaker"))
        #expect(prompt.partialRequests(maxContextTokens: 8_192)[0][1].content.contains("# Invited participants\n- Anna Bianchi"))
        let without = SummaryPrompt(template: template, personalNotes: "", transcript: transcript, meetingLanguage: "it")
        #expect(!without.singleRequest()[1].content.contains("Invited participants"))
        #expect(!without.singleRequest()[0].content.contains("invited"))
    }

    @Test("starred paragraphs get priority, in the single and in the partial requests")
    func marks() {
        let marked = SummaryPrompt(
            template: template, personalNotes: "", transcript: transcript.marking([1]), meetingLanguage: "it"
        )
        let unmarked = SummaryPrompt(template: template, personalNotes: "", transcript: transcript, meetingLanguage: "it")

        #expect(marked.singleRequest()[0].content.contains("Paragraphs starting with ⭐ were marked as important"))
        #expect(marked.partialRequests(maxContextTokens: 8_192)[0][0].content.contains("⭐"))
        #expect(!unmarked.singleRequest()[0].content.contains("⭐"))
    }
}
