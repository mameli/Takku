import Foundation
import Testing
import TakkuCore

/// One at a time: OpenCode's runs clear leftover sessions only when no other run of the app is going.
@Suite("Agent CLIs as Providers", .serialized)
struct AgentCLITests {
    static let meeting = [
        ChatMessage(role: .system, content: "Write a title."),
        ChatMessage(role: .user, content: "Il rilascio slitta al 20."),
    ]

    static let codexReply = """
        {"type":"thread.started","thread_id":"t"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"item_0","type":"command_execution","command":"ls"}}
        {"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Prima bozza"}}
        {"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Il rilascio è venerdì."}}
        {"type":"turn.completed","usage":{"input_tokens":15227,"cached_input_tokens":11520,"output_tokens":28}}
        """

    @Test("a Codex run keeps nothing, reads none of the user's Codex setup, has no tools, and its last message comes back")
    func codex() async throws {
        let fake = try FakeCLI(.codex, [.init(pattern: "exec*", script: FakeCLI.prints(Self.codexReply))])

        let reply = try await fake.runner().client(for: AgentCLI.codex.profile()).complete(Self.meeting)

        #expect(reply == "Il rilascio è venerdì.")
        let run = try #require(fake.calls.first)
        let line = run.arguments.joined(separator: " ")
        #expect(run.arguments.first == "exec")
        #expect(run.arguments.last == "-")
        for flag in ["--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--json"] {
            #expect(run.arguments.contains(flag))
        }
        for feature in ["shell_tool", "unified_exec", "hooks", "memories", "plugins", "browser_use", "computer_use", "apps"] {
            #expect(line.contains("--disable \(feature)"))
        }
        #expect(line.contains("--sandbox read-only"))
        #expect(line.contains("-c project_doc_max_bytes=0"))
        #expect(run.ranIn(run.value(after: "-C")))
        #expect(run.files.isEmpty)
        #expect(line.contains("-c model_reasoning_effort=\"low\""))
        #expect(!run.arguments.contains("-m"))
        #expect(run.input.contains("Do not run commands"))
        #expect(run.input.contains("<instructions>\nWrite a title.\n</instructions>"))
        #expect(run.input.contains("<request>\nIl rilascio slitta al 20.\n</request>"))
    }

    @Test("what the run used and the tools it tried reach the Summary log with the reply, and the agent's name as the model")
    func summaryLog() async throws {
        let fake = try FakeCLI(.codex, [.init(pattern: "exec*", script: FakeCLI.prints(Self.codexReply))])
        let log = SummaryLog.Recorder()

        _ = try await fake.runner().client(for: AgentCLI.codex.profile()).recording(into: log, as: .single).complete(Self.meeting)

        let response = try #require(await log.calls.first?.response)
        let body = try #require(try JSONSerialization.jsonObject(with: response) as? [String: Any])
        let agent = try #require(body["agent"] as? [String: Any])
        #expect(body["model"] as? String == "Codex")
        #expect(agent["usage"] as? String == "15227 tokens in, 28 out")
        #expect(agent["tool_calls"] as? Int == 1)
    }

    @Test("the Profile's model and reasoning level go to Codex")
    func codexModel() async throws {
        let fake = try FakeCLI(.codex, [.init(pattern: "exec*", script: FakeCLI.prints(Self.codexReply))])
        var profile = AgentCLI.codex.profile()
        profile.model = " gpt-6-luna "
        profile.reasoning = .high

        _ = try await fake.runner().client(for: profile).complete(Self.meeting)

        let run = try #require(fake.calls.first)
        #expect(run.value(after: "-m") == "gpt-6-luna")
        #expect(run.arguments.contains("model_reasoning_effort=\"high\""))
    }

    @Test("a failed Codex run gives the provider's own message, not the JSON around it")
    func codexFailure() async throws {
        let events = #"""
            {"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for `x` not found."}}
            {"type":"error","message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'x' model is not supported when using Codex with a ChatGPT account.\"}}"}
            {"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'x' model is not supported when using Codex with a ChatGPT account.\"}}"}}
            """#
        let fake = try FakeCLI(.codex, [.init(pattern: "exec*", script: FakeCLI.prints(events, exit: 1))])

        await #expect(throws: AgentCLI.Failure.failed(.codex, "The 'x' model is not supported when using Codex with a ChatGPT account.")) {
            try await fake.runner().client(for: AgentCLI.codex.profile()).complete(Self.meeting)
        }
    }

    @Test("a run that exits with an error and no events gives the last line it printed")
    func exitWithoutEvents() async throws {
        let fake = try FakeCLI(.codex, [.init(pattern: "exec*", script: "echo 'Il rilascio slitta' >&2\necho 'error: unexpected argument --ephemeral' >&2\nexit 2")])

        await #expect(throws: AgentCLI.Failure.failed(.codex, "error: unexpected argument --ephemeral")) {
            try await fake.runner().client(for: AgentCLI.codex.profile()).complete(Self.meeting)
        }
    }

    @Test("a run that fails for the sign-in says the CLI is not signed in")
    func signedOutRun() async throws {
        let fake = try FakeCLI(.copilot, [.init(pattern: "*", script: FakeCLI.prints("""
            {"type":"session.error","data":{"message":"No authentication information found. Run copilot login to sign in."}}
            {"type":"result","exitCode":1,"usage":{"premiumRequests":0}}
            """, exit: 1))])

        await #expect(throws: AgentCLI.Failure.notSignedIn(.copilot)) {
            try await fake.runner().client(for: AgentCLI.copilot.profile()).complete(Self.meeting)
        }
    }

    @Test("a run that ends without a word is an empty reply")
    func emptyReply() async throws {
        let fake = try FakeCLI(.codex, [.init(pattern: "exec*", script: FakeCLI.prints("""
            {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"  \\n"}}
            {"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":0}}
            """))])

        await #expect(throws: AgentCLI.Failure.emptyReply(.codex)) {
            try await fake.runner().client(for: AgentCLI.codex.profile()).complete(Self.meeting)
        }
    }

    @Test("a run that never answers stops with a timeout")
    func timeout() async throws {
        let fake = try FakeCLI(.codex, [.init(pattern: "exec*", script: "exec sleep 30")])

        await #expect(throws: AgentCLI.Failure.timedOut(.codex)) {
            try await fake.runner(timeout: .milliseconds(500)).client(for: AgentCLI.codex.profile()).complete(Self.meeting)
        }
    }

    @Test("stopping the request ends the CLI")
    func cancellation() async throws {
        let fake = try FakeCLI(.codex, [.init(pattern: "exec*", script: "exec sleep 30")])
        let client = fake.runner().client(for: AgentCLI.codex.profile())

        let request = Task { try await client.complete(Self.meeting) }
        let pid = try await Self.pid(of: fake)
        request.cancel()

        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(kill(pid, 0) != 0)
    }

    @Test("not installed: the CLI is not found")
    func notInstalled() async throws {
        let runner = AgentCLI.Runner(.claude, locate: { nil })

        await #expect(throws: AgentCLI.Failure.notInstalled(.claude)) {
            try await runner.client(for: AgentCLI.claude.profile()).complete(Self.meeting)
        }
        #expect(await runner.unavailability() == .notInstalled(.claude))
    }

    @Test("API keys and the agents' own variables never reach the CLI, so the plan pays and not the key", arguments: AgentCLI.allCases)
    func noAPIKeys(cli: AgentCLI) async throws {
        let fake = try FakeCLI(cli, [.init(pattern: "*", script: "exit 1")])
        let environment = [
            "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LANG": "it_IT.UTF-8",
            "ANTHROPIC_API_KEY": "sk-ant", "ANTHROPIC_BASE_URL": "https://example.com", "CLAUDECODE": "1",
            "CLAUDE_CODE_ENTRYPOINT": "cli", "OPENAI_API_KEY": "sk-openai", "CODEX_API_KEY": "sk-codex",
            "GITHUB_TOKEN": "ghp", "GH_TOKEN": "gho", "COPILOT_GITHUB_TOKEN": "ghc", "OPENROUTER_API_KEY": "sk-or",
            "GROQ_API_KEY": "gsk", "OPENCODE_CONFIG": "/Users/x/.config/opencode/opencode.json",
        ]
        var profile = cli.profile()
        profile.model = "provider/model"

        _ = try? await fake.runner(environment: environment).client(for: profile).complete(Self.meeting)

        let run = try #require(fake.calls.first)
        for name in environment.keys where !["PATH", "HOME", "LANG"].contains(name) {
            #expect(run.environment[name] == nil, "\(name) reached \(cli.name)")
        }
        #expect(run.environment["LANG"] == "it_IT.UTF-8")
        #expect(run.environment["PATH"]?.hasPrefix(fake.executable.deletingLastPathComponent().path + ":/opt/homebrew/bin") == true)
    }

    // MARK: - GitHub Copilot

    static let copilotReply = """
        {"type":"session.auto_mode_resolved","data":{"chosenModel":"gpt-6-luna"}}
        {"type":"assistant.message_delta","data":{"deltaContent":"Il"}}
        {"type":"assistant.message","data":{"content":"","toolRequests":[{"toolCallId":"call_1","name":"bash"}]}}
        {"type":"assistant.message","data":{"content":"Il rilascio è venerdì.","toolRequests":[]}}
        {"type":"result","exitCode":0,"usage":{"premiumRequests":1,"totalApiDurationMs":1600}}
        """

    @Test("a Copilot run has no tools, none of the user's instructions or MCP servers, an empty home, and auto gets no reasoning level")
    func copilot() async throws {
        let fake = try FakeCLI(.copilot, [.init(pattern: "*", script: FakeCLI.prints(Self.copilotReply))])
        var profile = AgentCLI.copilot.profile()
        profile.reasoning = .low

        let reply = try await fake.runner().client(for: profile).complete(Self.meeting)

        #expect(reply == "Il rilascio è venerdì.")
        let run = try #require(fake.calls.first)
        for flag in ["--no-custom-instructions", "--disable-builtin-mcps", "--no-ask-user", "--no-remote-export", "--no-auto-update"] {
            #expect(run.arguments.contains(flag))
        }
        // An empty --available-tools would leave every tool.
        #expect(run.arguments.contains("--available-tools=takku_none"))
        #expect(!run.arguments.contains("--available-tools"))
        #expect(!run.arguments.contains { $0.hasPrefix("--allow-all") || $0 == "--yolo" })
        #expect(run.value(after: "--output-format") == "json")
        #expect(run.ranIn(run.value(after: "-C")))
        #expect(!run.arguments.contains("--model"))
        #expect(!run.arguments.contains("--reasoning-effort"))
        let home = try #require(run.environment["COPILOT_HOME"])
        #expect(!home.contains(NSHomeDirectory() + "/.copilot"))
        #expect(!run.ranIn(home))
        #expect(run.input.contains("Do not run commands"))
    }

    @Test("a named Copilot model gets the reasoning level; auto, named or not, never does")
    func copilotModel() async throws {
        let fake = try FakeCLI(.copilot, [.init(pattern: "*", script: FakeCLI.prints(Self.copilotReply))])
        var profile = AgentCLI.copilot.profile()
        profile.reasoning = .medium

        profile.model = "claude-sonnet-5.5"
        _ = try await fake.runner().client(for: profile).complete(Self.meeting)
        profile.model = "auto"
        _ = try await fake.runner().client(for: profile).complete(Self.meeting)

        let (named, auto) = (fake.calls[0], fake.calls[1])
        #expect(named.value(after: "--model") == "claude-sonnet-5.5")
        #expect(named.value(after: "--reasoning-effort") == "medium")
        #expect(auto.value(after: "--model") == "auto")
        #expect(!auto.arguments.contains("--reasoning-effort"))
    }

    @Test("a failed Copilot run gives the session's error")
    func copilotFailure() async throws {
        let fake = try FakeCLI(.copilot, [.init(pattern: "*", script: FakeCLI.prints("""
            {"type":"session.error","data":{"message":"Rate limit exceeded"}}
            {"type":"result","exitCode":1,"usage":{"premiumRequests":0}}
            """, exit: 1))])

        await #expect(throws: AgentCLI.Failure.failed(.copilot, "Rate limit exceeded")) {
            try await fake.runner().client(for: AgentCLI.copilot.profile()).complete(Self.meeting)
        }
    }

    // MARK: - Claude Code

    static let claudeReply = """
        {"duration_api_ms":788,"stop_reason":"end_turn","session_id":"ef8b13c5-84d5-426d-9364-20f68ffaa639","total_cost_usd":0.000453,"usage":{"input_tokens":433,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":4,"output_tokens_details":{"thinking_tokens":0},"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard"},"modelUsage":{"claude-haiku-4-5-20251001":{"inputTokens":433,"outputTokens":4,"costUSD":0.000453,"contextWindow":200000,"costBasis":"list"}},"permission_denials":[],"terminal_reason":"completed","is_error":false,"num_turns":1,"subtype":"success","api_error_status":null,"result":"Il rilascio è venerdì.","type":"result","duration_ms":816}
        """

    @Test("a Claude Code run has no tools, settings, MCP servers or session, Takku's system prompt, and reasoning off by default")
    func claude() async throws {
        let fake = try FakeCLI(.claude, [.init(pattern: "-p*", script: FakeCLI.prints(Self.claudeReply))])

        let reply = try await fake.runner().client(for: AgentCLI.claude.profile()).complete(Self.meeting)

        #expect(reply == "Il rilascio è venerdì.")
        let run = try #require(fake.calls.first)
        for flag in ["-p", "--safe-mode", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence"] {
            #expect(run.arguments.contains(flag))
        }
        // --bare ignores the plan's sign-in.
        #expect(!run.arguments.contains("--bare"))
        #expect(run.value(after: "--output-format") == "json")
        #expect(run.value(after: "--setting-sources") == "")
        #expect(run.value(after: "--tools") == "")
        #expect(run.value(after: "--system-prompt")?.contains("no tools") == true)
        #expect(run.value(after: "--settings") == #"{"alwaysThinkingEnabled":false}"#)
        #expect(!run.arguments.contains("--effort"))
        #expect(!run.arguments.contains("--model"))
        #expect(run.files.isEmpty)
        #expect(!run.input.contains("Do not run commands"))
        #expect(run.input.contains("<instructions>\nWrite a title.\n</instructions>"))
    }

    @Test("Claude Code gets the model, and a reasoning level as its effort with thinking left to it")
    func claudeModel() async throws {
        let fake = try FakeCLI(.claude, [.init(pattern: "-p*", script: FakeCLI.prints(Self.claudeReply))])
        var profile = AgentCLI.claude.profile()
        profile.model = "sonnet"
        profile.reasoning = .medium

        _ = try await fake.runner().client(for: profile).complete(Self.meeting)

        let run = try #require(fake.calls.first)
        #expect(run.value(after: "--model") == "sonnet")
        #expect(run.value(after: "--effort") == "medium")
        #expect(!run.arguments.contains("--settings"))
    }

    @Test("a failed Claude Code run gives its message, though it says \"success\"")
    func claudeFailure() async throws {
        let fake = try FakeCLI(.claude, [.init(pattern: "-p*", script: """
            echo '[claude-code:unrecognized_model] {"model":"x"}' >&2
            \(FakeCLI.prints("""
            {"duration_api_ms":0,"stop_reason":"stop_sequence","session_id":"e15958af","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0},"modelUsage":{},"permission_denials":[],"terminal_reason":"api_error","is_error":true,"num_turns":1,"subtype":"success","api_error_status":404,"result":"There's an issue with the selected model (x). It may not exist or you may not have access to it. Run --model to pick a different model.","type":"result","duration_ms":629}
            """, exit: 1))
            """)])

        await #expect(throws: AgentCLI.Failure.failed(
            .claude, "There's an issue with the selected model (x). It may not exist or you may not have access to it. Run --model to pick a different model."
        )) {
            try await fake.runner().client(for: AgentCLI.claude.profile()).complete(Self.meeting)
        }
    }

    // MARK: - OpenCode

    static let openCodeReply = """
        {"type":"step_start","timestamp":1793804413666,"sessionID":"ses_run","part":{"id":"prt_1","sessionID":"ses_run","messageID":"msg_1","type":"step-start"}}
        {"type":"tool_use","timestamp":1793804413700,"sessionID":"ses_run","part":{"id":"prt_2","sessionID":"ses_run","messageID":"msg_1","type":"tool","tool":"read","state":{"status":"error","error":"denied"}}}
        {"type":"text","timestamp":1793804414100,"sessionID":"ses_run","part":{"id":"prt_3","sessionID":"ses_run","messageID":"msg_1","type":"text","text":"Il rilascio è venerdì."}}
        {"type":"step_finish","timestamp":1793804414177,"sessionID":"ses_run","part":{"id":"prt_4","sessionID":"ses_run","messageID":"msg_1","type":"step-finish","reason":"stop","tokens":{"input":2210,"output":9,"reasoning":0,"cache":{"read":0,"write":0}},"cost":0}}
        """

    static let openCodeFailure = #"""
        {"type":"step_start","timestamp":1793804413666,"sessionID":"ses_run","part":{"id":"prt_1","sessionID":"ses_run","messageID":"msg_1","type":"step-start"}}
        {"type":"error","timestamp":1793804414182,"sessionID":"ses_run","error":{"type":"provider.free-limit","message":"Free usage limit reached. Connect a provider or subscribe to OpenCode Go to keep going, or switch models.","status":429,"response":{"body":"{\"type\":\"error\"}"},"retryAfterMs":32386000}}
        """#

    /// What `session list` prints: a session an earlier run left, and two of the user's (one
    /// titled like Takku's, elsewhere).
    static let openCodeSessions = """
        printf '[{"id":"ses_left","title":"Takku","directory":"%s"},{"id":"ses_user","title":"Takku","directory":"/Users/x/code"},{"id":"ses_mine","title":"Refactor","directory":"%s"}]' "$PWD" "$PWD"
        """

    static func openCode(run: String) throws -> FakeCLI {
        try FakeCLI(.opencode, [
            .init(pattern: "session list*", script: openCodeSessions),
            .init(pattern: "session delete*", script: "echo deleted"),
            .init(pattern: "run *", script: run),
        ])
    }

    static var openCodeProfile: ProviderProfile {
        var profile = AgentCLI.opencode.profile()
        profile.model = "openrouter/~anthropic/claude-haiku-latest"
        return profile
    }

    @Test("an OpenCode run uses Takku's agent with every tool denied and none of the user's config, then deletes its session")
    func openCode() async throws {
        let fake = try Self.openCode(run: FakeCLI.prints(Self.openCodeReply))

        let reply = try await fake.runner().client(for: Self.openCodeProfile).complete(Self.meeting)

        #expect(reply == "Il rilascio è venerdì.")
        let run = try #require(fake.calls(startingWith: ["run"]).first)
        #expect(run.arguments.contains("--standalone"))
        #expect(run.value(after: "--format") == "json")
        #expect(run.value(after: "--agent") == "takku")
        #expect(run.value(after: "-m") == "openrouter/~anthropic/claude-haiku-latest")
        #expect(run.environment["OPENCODE_DISABLE_PROJECT_CONFIG"] == "1")
        #expect(run.environment["OPENCODE_DISABLE_CLAUDE_CODE"] == "1")
        #expect(run.environment["OPENCODE_DISABLE_AUTOUPDATE"] == "1")
        let configFolder = try #require(run.environment["OPENCODE_CONFIG_DIR"])
        #expect(!configFolder.hasPrefix(NSHomeDirectory()))
        let config = try #require(try JSONSerialization.jsonObject(
            with: Data((run.environment["OPENCODE_CONFIG_CONTENT"] ?? "").utf8)
        ) as? [String: Any])
        #expect(config["plugins"] as? [String] == ["-opencode.tool.skill", "-opencode.skill"])
        let agent = try #require((config["agents"] as? [String: Any])?["takku"] as? [String: Any])
        #expect(agent["permissions"] as? [[String: String]] == [["action": "*", "resource": "*", "effect": "deny"]])
        #expect((agent["system"] as? String)?.contains("no tools") == true)
        #expect(run.files.isEmpty)
        #expect(!run.input.contains("Do not run commands"))
        #expect(fake.calls(startingWith: ["session", "delete"]).map(\.arguments.last) == ["ses_left", "ses_run"])
    }

    @Test("an OpenCode run that fails gives OpenCode's message and deletes its session too")
    func openCodeFailure() async throws {
        let fake = try Self.openCode(run: FakeCLI.prints(Self.openCodeFailure, exit: 1))

        await #expect(throws: AgentCLI.Failure.failed(
            .opencode, "Free usage limit reached. Connect a provider or subscribe to OpenCode Go to keep going, or switch models."
        )) {
            try await fake.runner().client(for: Self.openCodeProfile).complete(Self.meeting)
        }
        #expect(fake.calls(startingWith: ["session", "delete"]).map(\.arguments.last) == ["ses_left", "ses_run"])
    }

    @Test("OpenCode with no model does not run: it has no default of its own")
    func openCodeWithoutModel() async throws {
        let fake = try Self.openCode(run: FakeCLI.prints(Self.openCodeReply))

        await #expect(throws: AgentCLI.Failure.noModel(.opencode)) {
            try await fake.runner().client(for: AgentCLI.opencode.profile()).complete(Self.meeting)
        }
        #expect(fake.calls.isEmpty)
    }

    @Test("a stopped OpenCode run still has its session deleted")
    func openCodeCancellation() async throws {
        let fake = try Self.openCode(run: """
            echo '{"type":"step_start","timestamp":1,"sessionID":"ses_run","part":{"type":"step-start"}}'
            exec sleep 30
            """)
        let client = fake.runner().client(for: Self.openCodeProfile)

        let request = Task { try await client.complete(Self.meeting) }
        for _ in 0..<100 where fake.calls(startingWith: ["run"]).isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(100))
        request.cancel()

        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(fake.calls(startingWith: ["session", "delete"]).map(\.arguments.last) == ["ses_left", "ses_run"])
    }

    // MARK: - Sign-in

    @Test("a signed-out CLI says so before any run; Copilot cannot tell")
    func signedOut() async throws {
        let codex = try FakeCLI(.codex, [.init(pattern: "login status", script: "echo 'Not logged in' >&2\nexit 1")])
        let claude = try FakeCLI(.claude, [.init(pattern: "auth status", script: FakeCLI.prints(#"{"loggedIn":false,"authMethod":"none"}"#, exit: 1))])
        let openCode = try FakeCLI(.opencode, [.init(pattern: "auth list*", script: FakeCLI.prints("[]"))])
        let copilot = try FakeCLI(.copilot, [])

        #expect(await codex.runner().unavailability() == .notSignedIn(.codex))
        #expect(await claude.runner().unavailability() == .notSignedIn(.claude))
        #expect(await openCode.runner().unavailability() == .notSignedIn(.opencode))
        #expect(await copilot.runner().unavailability() == nil)
        #expect(copilot.calls.isEmpty)
    }

    @Test("a signed-in CLI has no problem")
    func signedIn() async throws {
        let codex = try FakeCLI(.codex, [.init(pattern: "login status", script: "echo 'Logged in using ChatGPT'")])
        let claude = try FakeCLI(.claude, [.init(pattern: "auth status", script: FakeCLI.prints(#"{"loggedIn":true,"authMethod":"claude.ai"}"#))])
        let openCode = try FakeCLI(.opencode, [.init(pattern: "auth list*", script: FakeCLI.prints("""
            [{"id":"openrouter","name":"OpenRouter","connections":[{"type":"credential","id":"cred_1","label":"OpenRouter","method":"key"}]}]
            """))])

        #expect(await codex.runner().unavailability() == nil)
        #expect(await claude.runner().unavailability() == nil)
        #expect(await openCode.runner().unavailability() == nil)
    }

    // MARK: - Models

    @Test("Codex lists the models of its own picker, each with the reasoning levels it accepts")
    func codexModels() async throws {
        let fake = try FakeCLI(.codex, [.init(pattern: "debug models", script: FakeCLI.prints("""
            {"models":[{"slug":"gpt-6-chat-thinking","visibility":"hide","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"}]},{"slug":"gpt-6-luna","visibility":"list","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low","description":"Fast"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}]},{"slug":"gpt-5.6-mini","visibility":"list","supported_reasoning_levels":[{"effort":"medium"},{"effort":"high"}]}]}
            """))])

        let models = try #require(await fake.runner().models())

        #expect(models == [AgentCLI.Model("gpt-6-luna", reasoning: [.low, .medium, .high]), AgentCLI.Model("gpt-5.6-mini", reasoning: [.medium, .high])])
        #expect(AgentCLI.codex.reasoningLevels(for: "gpt-5.6-mini", in: models) == [.medium, .high])
        #expect(AgentCLI.codex.reasoningLevels(for: "", in: models) == [.medium, .high])
        #expect(AgentCLI.codex.reasoningLevels(for: "gpt-7", in: models) == ProviderProfile.ReasoningEffort.allCases)
    }

    @Test("OpenCode lists the models of the Providers signed in to")
    func openCodeModels() async throws {
        let fake = try FakeCLI(.opencode, [.init(pattern: "models", script: FakeCLI.prints("""
            opencode/big-pickle
            openrouter/~anthropic/claude-haiku-latest
            """))])

        let models = await fake.runner().models()

        #expect(models == [AgentCLI.Model("opencode/big-pickle"), AgentCLI.Model("openrouter/~anthropic/claude-haiku-latest")])
        #expect(!AgentCLI.opencode.hasDefaultModel)
        #expect(AgentCLI.opencode.reasoningLevels(for: "opencode/big-pickle", in: models) == nil)
    }

    @Test("a list that cannot be read leaves the model to be typed")
    func unreadableModels() async throws {
        let fake = try FakeCLI(.codex, [.init(pattern: "debug models", script: "echo 'unknown command' >&2\nexit 2")])

        #expect(await fake.runner().models() == nil)
    }

    @Test("Claude Code offers its aliases and Copilot auto, without running")
    func fixedModels() async throws {
        let claude = try FakeCLI(.claude, [])
        let copilot = try FakeCLI(.copilot, [])

        #expect(await claude.runner().models()?.map(\.name) == ["fable", "opus", "sonnet", "haiku"])
        #expect(await copilot.runner().models()?.map(\.name) == ["auto"])
        #expect(AgentCLI.copilot.reasoningLevels(for: "", in: nil) == [])
        #expect(claude.calls.isEmpty && copilot.calls.isEmpty)
    }

    @Test("new Profiles are light on the plan: Codex Low, Claude Code Off, Copilot and OpenCode the agent's own", arguments: AgentCLI.allCases)
    func newProfile(cli: AgentCLI) {
        let profile = cli.profile()

        #expect(profile.agentCLI == cli)
        #expect(!profile.runsOnThisMac)
        #expect(profile.model.isEmpty)
        #expect(profile.maxContextTokens == 128_000)
        #expect(profile.reasoning == [AgentCLI.codex: .low, .claude: .off][cli])
    }

    /// The process the fake CLI's run is, once it started.
    private static func pid(of fake: FakeCLI) async throws -> Int32 {
        for _ in 0..<100 {
            if let pid = fake.calls.first?.pid { return pid }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CancellationError()
    }
}
