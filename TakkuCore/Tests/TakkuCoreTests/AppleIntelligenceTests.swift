import Foundation
import Testing
import TakkuCore

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [Int] = []
    func add(_ size: Int) { lock.withLock { sizes.append(size) } }
    var count: Int { lock.withLock { sizes.count } }
    var largest: Int { lock.withLock { sizes.max() ?? 0 } }
}

@Suite("Apple Intelligence as a Provider")
struct AppleIntelligenceTests {
    /// A ChatClient whose transport answers as the model would, echoing what it was asked.
    func client(answer: @escaping @Sendable (_ instructions: String, _ prompt: String) -> String) -> ChatClient {
        ChatClient(baseURL: URL(string: AppleIntelligence.baseURL)!, apiKey: nil, model: AppleIntelligence.model) { request in
            let (instructions, prompt) = try AppleIntelligence.conversation(fromRequestBody: request.httpBody ?? Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (AppleIntelligence.responseBody(answer(instructions, prompt)), response)
        }
    }

    @Test("system messages become the instructions, the others the prompt, and the reply comes back as text")
    func roundTrip() async throws {
        let reply = try await client { instructions, prompt in "[\(instructions)] [\(prompt)]" }.complete([
            ChatMessage(role: .system, content: "Write a title."),
            ChatMessage(role: .user, content: "Il rilascio slitta al 20."),
        ])

        #expect(reply == "[Write a title.] [Il rilascio slitta al 20.]")
    }

    @Test("its Profile is recognised, runs on this Mac, and keeps the context it was given")
    func profile() {
        let profile = AppleIntelligence.profile(contextTokens: 8_192)

        #expect(profile.isAppleIntelligence)
        #expect(profile.runsOnThisMac)
        #expect(profile.maxContextTokens == 8_192)
        #expect(!ProviderProfile.takkuCredit().isAppleIntelligence)
    }

    @Test("its small context keeps a quarter for the reply, so a Transcript still fits in blocks; other Profiles keep 4,096")
    func smallContext() async throws {
        let profile = AppleIntelligence.profile(contextTokens: 4_096)
        #expect(profile.replyReserveTokens == 1_024)
        #expect(ProviderProfile.takkuCredit().replyReserveTokens == 4_096)

        let transcript = Transcript(utterances: (0..<60).map {
            Utterance(track: $0.isMultiple(of: 2) ? .others : .me, start: Double($0 * 20), end: Double($0 * 20 + 15), text: String(repeating: "parole della riunione ", count: 12))
        })
        var prompt = SummaryPrompt(
            template: Template(fileName: "Notes", content: "### Topics"), personalNotes: "", transcript: transcript, meetingLanguage: "it"
        )
        prompt.replyRoom = profile.replyReserveTokens
        let calls = Calls()
        let summary = try await Summarizer(client: client { _, prompt in calls.add(prompt.count); return "- punto" }, maxContextTokens: 4_096, isReportedContext: true)
            .summarize(prompt)

        #expect(summary.text.contains("punto"))
        #expect(calls.count > 2)
        #expect(calls.largest / 3 + profile.replyReserveTokens <= 4_096)
    }

    @Test("a title without a Summary is asked from the start of the Transcript, short enough for the model")
    func titleFromTranscript() {
        let long = Transcript(utterances: (0..<400).map {
            Utterance(track: .others, start: Double($0 * 10), end: Double($0 * 10 + 8), text: "Parliamo del rilascio di novembre.")
        })
        let request = MeetingTitle.request(transcript: long, language: "it")

        #expect(request.count == 2)
        #expect(request[1].content.count == MeetingTitle.transcriptExcerptCharacters)
        #expect(request[1].content.hasPrefix("**[00:00]"))
    }

    @Test("a repeated list marker becomes one, keeping the indent and the checkbox")
    func repeatedMarkers() {
        #expect(AppleIntelligence.cleaned("""
            ### Topics
            - - [ ] Chiedere ad Ale la finestra di rilascio
              - - il rilascio slitta al 20
            - una riga normale
            """) == """
            ### Topics
            - [ ] Chiedere ad Ale la finestra di rilascio
              - il rilascio slitta al 20
            - una riga normale
            """)
    }
}
