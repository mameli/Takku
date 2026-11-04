import Foundation
import Testing
import TakkuCore

@Suite("Agent CLIs as Providers")
struct AgentCLITests {
    let folder = URL(filePath: "/tmp/Takku-cli-test/work")

    @Test("their Profiles are recognised, have no model of their own, and do not run on this Mac", arguments: AgentCLI.allCases)
    func profile(cli: AgentCLI) {
        let profile = cli.profile()

        #expect(profile.agentCLI == cli)
        #expect(!profile.isAppleIntelligence)
        #expect(!profile.runsOnThisMac)
        #expect(profile.model.isEmpty)
        #expect(ProviderProfile.takkuCredit().agentCLI == nil)
        #expect(AgentCLI.codex.baseURL != AgentCLI.copilot.baseURL)
    }

    @Test("a Codex run keeps nothing, reads none of the user's Codex setup, has no tools, and takes the prompt from standard input")
    func codexArguments() {
        let arguments = AgentCLI.codex.arguments(model: "", reasoning: nil, folder: folder)
        let line = arguments.joined(separator: " ")

        for flag in ["--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--json"] {
            #expect(arguments.contains(flag))
        }
        for feature in ["shell_tool", "unified_exec", "hooks", "memories", "plugins", "browser_use", "computer_use"] {
            #expect(line.contains("--disable \(feature)"))
        }
        #expect(arguments.first == "exec")
        #expect(arguments.last == "-")
        #expect(arguments.contains("project_doc_max_bytes=0"))
        #expect(line.contains("--sandbox read-only"))
        #expect(line.contains("-C /tmp/Takku-cli-test/work"))
        #expect(!arguments.contains("-m"))
        #expect(!arguments.contains { $0.hasPrefix("model_reasoning_effort") })
        #expect(AgentCLI.codex.environment(folder: folder).isEmpty)
    }

    @Test("a Copilot run has no tools and none of the user's instructions or MCP servers, and an empty home of its own")
    func copilotArguments() {
        let arguments = AgentCLI.copilot.arguments(model: "", reasoning: nil, folder: folder)

        for flag in ["--no-custom-instructions", "--disable-builtin-mcps", "--no-ask-user", "--no-remote-export", "--no-auto-update"] {
            #expect(arguments.contains(flag))
        }
        // An empty --available-tools would leave every tool.
        #expect(arguments.contains("--available-tools=takku_none"))
        #expect(!arguments.contains("--available-tools"))
        #expect(!arguments.contains { $0.hasPrefix("--allow-all") || $0 == "--yolo" })
        #expect(arguments.joined(separator: " ").contains("--output-format json"))
        #expect(arguments.joined(separator: " ").contains("-C /tmp/Takku-cli-test/work"))
        #expect(!arguments.contains("--model"))
        #expect(AgentCLI.copilot.environment(folder: folder) == ["COPILOT_HOME": "/tmp/Takku-cli-test/copilot-home"])
    }

    @Test("the model and the reasoning go to the CLI when the Profile has them, \"off\" as none")
    func modelAndReasoning() {
        let codex = AgentCLI.codex.arguments(model: " gpt-6-luna ", reasoning: .off, folder: folder).joined(separator: " ")
        let copilot = AgentCLI.copilot.arguments(model: "claude-sonnet-5.5", reasoning: .medium, folder: folder).joined(separator: " ")

        #expect(codex.contains("-m gpt-6-luna"))
        #expect(codex.contains("-c model_reasoning_effort=\"none\""))
        #expect(copilot.contains("--model claude-sonnet-5.5"))
        #expect(copilot.contains("--reasoning-effort medium"))
    }

    @Test("Copilot's own model, auto, gets no reasoning level: it refuses any")
    func copilotAuto() {
        let arguments = AgentCLI.copilot.arguments(model: "", reasoning: .low, folder: folder)

        #expect(!arguments.contains("--reasoning-effort"))
        #expect(AgentCLI.copilot.profile().reasoning == nil)
        #expect(AgentCLI.codex.profile().reasoning == .low)
    }

    @Test("the request reaches the CLI as instructions and request, told to answer with the text alone")
    func input() throws {
        let body = try JSONSerialization.data(withJSONObject: ["messages": [
            ["role": "system", "content": "Write a title."],
            ["role": "user", "content": "Il rilascio slitta al 20."],
        ]])

        let input = try AgentCLI.input(fromRequestBody: body)

        #expect(input.contains("Do not run commands"))
        #expect(input.contains("<instructions>\nWrite a title.\n</instructions>"))
        #expect(input.contains("<request>\nIl rilascio slitta al 20.\n</request>"))
    }

    @Test("a finished Codex run gives its last message and the tokens it used")
    func codexReply() {
        let events = """
            {"type":"thread.started","thread_id":"t"}
            {"type":"turn.started"}
            {"type":"item.completed","item":{"id":"item_0","type":"command_execution","command":"ls"}}
            {"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Prima bozza"}}
            {"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Il rilascio è venerdì."}}
            {"type":"turn.completed","usage":{"input_tokens":15227,"cached_input_tokens":11520,"output_tokens":28}}
            """

        let outcome = AgentCLI.codex.outcome(ofEvents: Data(events.utf8))

        #expect(outcome.reply == "Il rilascio è venerdì.")
        #expect(outcome.failure == nil)
        #expect(outcome.usage == "15227 tokens in, 28 out")
        #expect(outcome.toolCalls == 1)
    }

    @Test("a failed Codex run gives the provider's own message, not the JSON around it; a warning is not a failure")
    func codexFailure() {
        let events = #"""
            {"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for `x` not found."}}
            {"type":"error","message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'x' model is not supported when using Codex with a ChatGPT account.\"}}"}
            {"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'x' model is not supported when using Codex with a ChatGPT account.\"}}"}}
            """#

        let outcome = AgentCLI.codex.outcome(ofEvents: Data(events.utf8))

        #expect(outcome.reply == nil)
        #expect(outcome.failure == "The 'x' model is not supported when using Codex with a ChatGPT account.")
        #expect(outcome.toolCalls == 0)
    }

    @Test("a finished Copilot run gives its last message with text, the tools it asked for, and the premium requests")
    func copilotReply() {
        let events = """
            {"type":"session.auto_mode_resolved","data":{"chosenModel":"gpt-6-luna"}}
            {"type":"assistant.message_delta","data":{"deltaContent":"Il"}}
            {"type":"assistant.message","data":{"content":"","toolRequests":[{"toolCallId":"call_1","name":"bash"}]}}
            {"type":"assistant.message","data":{"content":"Il rilascio è venerdì.","toolRequests":[]}}
            {"type":"result","exitCode":0,"usage":{"premiumRequests":1,"totalApiDurationMs":1600}}
            """

        let outcome = AgentCLI.copilot.outcome(ofEvents: Data(events.utf8))

        #expect(outcome.reply == "Il rilascio è venerdì.")
        #expect(outcome.failure == nil)
        #expect(outcome.usage == "1 premium requests")
        #expect(outcome.toolCalls == 1)
    }

    @Test("a failed Copilot run gives the session's error, or its exit code")
    func copilotFailure() {
        let withError = AgentCLI.copilot.outcome(ofEvents: Data("""
            {"type":"session.error","data":{"message":"Rate limit exceeded"}}
            {"type":"result","exitCode":1,"usage":{"premiumRequests":0}}
            """.utf8))
        let withoutError = AgentCLI.copilot.outcome(ofEvents: Data("""
            {"type":"result","exitCode":2,"usage":{"premiumRequests":0}}
            """.utf8))

        #expect(withError.reply == nil)
        #expect(withError.failure == "Rate limit exceeded")
        #expect(withoutError.failure == "exit 2")
    }

    @Test("the CLI's reply comes back through ChatClient as any Provider's would", arguments: AgentCLI.allCases)
    func roundTrip(cli: AgentCLI) async throws {
        let client = ChatClient(baseURL: URL(string: cli.baseURL)!, apiKey: nil, model: cli.name) { request in
            let input = try AgentCLI.input(fromRequestBody: request.httpBody ?? Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (cli.responseBody(input.contains("slitta") ? "Rilascio rinviato" : "?"), response)
        }

        let reply = try await client.complete([ChatMessage(role: .user, content: "Il rilascio slitta al 20.")])

        #expect(reply == "Rilascio rinviato")
    }
}
