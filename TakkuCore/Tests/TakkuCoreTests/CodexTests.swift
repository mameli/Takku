import Foundation
import Testing
import TakkuCore

@Suite("Codex as a Provider")
struct CodexTests {
    let folder = URL(filePath: "/tmp/Takku-Codex-test")

    @Test("its Profile is recognised, has no model of its own, and does not run on this Mac")
    func profile() {
        let profile = Codex.profile()

        #expect(profile.isCodex)
        #expect(!profile.isAppleIntelligence)
        #expect(!profile.runsOnThisMac)
        #expect(profile.model.isEmpty)
        #expect(!ProviderProfile.takkuCredit().isCodex)
    }

    @Test("a run keeps nothing, reads none of the user's Codex setup, and takes the prompt from standard input")
    func arguments() {
        let arguments = Codex.arguments(model: "", reasoning: nil, folder: folder)

        for flag in ["--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--json"] {
            #expect(arguments.contains(flag))
        }
        #expect(arguments.first == "exec")
        #expect(arguments.last == "-")
        #expect(arguments.contains("project_doc_max_bytes=0"))
        #expect(arguments.joined(separator: " ").contains("--sandbox read-only"))
        #expect(arguments.joined(separator: " ").contains("-C /tmp/Takku-Codex-test"))
        #expect(!arguments.contains("-m"))
        #expect(!arguments.contains { $0.hasPrefix("model_reasoning_effort") })
    }

    @Test("the model and the reasoning go to Codex when the Profile has them, \"off\" as none")
    func modelAndReasoning() {
        let arguments = Codex.arguments(model: " gpt-6-luna ", reasoning: .off, folder: folder).joined(separator: " ")

        #expect(arguments.contains("-m gpt-6-luna"))
        #expect(arguments.contains("-c model_reasoning_effort=\"none\""))
    }

    @Test("the request reaches Codex as instructions and request, told to answer with the text alone")
    func input() throws {
        let body = try JSONSerialization.data(withJSONObject: ["messages": [
            ["role": "system", "content": "Write a title."],
            ["role": "user", "content": "Il rilascio slitta al 20."],
        ]])

        let input = try Codex.input(fromRequestBody: body)

        #expect(input.contains("Do not run commands"))
        #expect(input.contains("<instructions>\nWrite a title.\n</instructions>"))
        #expect(input.contains("<request>\nIl rilascio slitta al 20.\n</request>"))
    }

    @Test("a finished run gives its last message and the tokens it used")
    func reply() {
        let events = """
            {"type":"thread.started","thread_id":"t"}
            {"type":"turn.started"}
            {"type":"item.completed","item":{"id":"item_0","type":"command_execution","command":"ls"}}
            {"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Prima bozza"}}
            {"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Il rilascio è venerdì."}}
            {"type":"turn.completed","usage":{"input_tokens":15227,"cached_input_tokens":11520,"output_tokens":28}}
            """

        let outcome = Codex.outcome(ofEvents: Data(events.utf8))

        #expect(outcome.reply == "Il rilascio è venerdì.")
        #expect(outcome.failure == nil)
        #expect(outcome.inputTokens == 15_227)
        #expect(outcome.outputTokens == 28)
        #expect(outcome.toolCalls == 1)
    }

    @Test("a failed run gives the provider's own message, not the JSON around it; a warning is not a failure")
    func failure() {
        let events = #"""
            {"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for `x` not found."}}
            {"type":"error","message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'x' model is not supported when using Codex with a ChatGPT account.\"}}"}
            {"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'x' model is not supported when using Codex with a ChatGPT account.\"}}"}}
            """#

        let outcome = Codex.outcome(ofEvents: Data(events.utf8))

        #expect(outcome.reply == nil)
        #expect(outcome.failure == "The 'x' model is not supported when using Codex with a ChatGPT account.")
        #expect(outcome.toolCalls == 0)
    }

    @Test("Codex's reply comes back through ChatClient as any Provider's would")
    func roundTrip() async throws {
        let client = ChatClient(baseURL: URL(string: Codex.baseURL)!, apiKey: nil, model: Codex.name) { request in
            let input = try Codex.input(fromRequestBody: request.httpBody ?? Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Codex.responseBody(input.contains("slitta") ? "Rilascio rinviato" : "?"), response)
        }

        let reply = try await client.complete([ChatMessage(role: .user, content: "Il rilascio slitta al 20.")])

        #expect(reply == "Rilascio rinviato")
    }
}
