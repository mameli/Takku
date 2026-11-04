import Foundation

/// A coding agent's CLI, installed and signed in by the user, as a Provider: the Summary is paid by
/// their plan (ChatGPT for Codex, GitHub Copilot for Copilot), and Takku holds no key and signs in
/// to nothing. Like Apple Intelligence, its Profile goes through `ChatClient`, whose transport hands
/// each Chat Completions request to one run of the CLI instead of the network and answers in the
/// same format, so Summaries in blocks, the title and the Summary log work as with any Provider.
/// The CLI sends the text to its provider: it does not run on this Mac.
///
/// A run has nothing of the user's coding setup and no tools: no session kept, no settings,
/// instructions (AGENTS.md), MCP servers, hooks, memories or plugins, no shell, in an empty folder.
public enum AgentCLI: String, CaseIterable, Sendable {
    case codex, copilot

    /// What its Profile is called.
    public var name: String {
        switch self {
        case .codex: "Codex"
        case .copilot: "GitHub Copilot"
        }
    }

    /// The executable's name.
    public var command: String { rawValue }

    /// Not an address: it marks the Profile, and the transport never sends it anywhere.
    public var baseURL: String { "\(rawValue)://this-mac" }

    /// What the agents' models take comfortably, after their own instructions (15,000 tokens or so).
    public static let contextTokens = 128_000

    /// A Profile for the CLI. An empty model is the one the CLI picks: for Copilot that is "auto",
    /// which takes no reasoning level.
    public func profile() -> ProviderProfile {
        ProviderProfile(
            name: name, baseURL: baseURL, model: "", maxContextTokens: Self.contextTokens, reasoning: self == .codex ? .low : nil
        )
    }

    /// The arguments for one run, which reads the prompt from standard input and writes its events
    /// as JSON lines (see `outcome(ofEvents:)`), in `folder`, empty.
    public func arguments(model: String, reasoning: ProviderProfile.ReasoningEffort?, folder: URL) -> [String] {
        let model = model.trimmingCharacters(in: .whitespaces)
        switch self {
        case .codex:
            // --ignore-user-config skips config.toml, not the features on by default: they are turned off here.
            var arguments = [
                "exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                "--sandbox", "read-only", "--color", "never", "--json",
                "-c", "project_doc_max_bytes=0",
            ]
            for feature in ["shell_tool", "unified_exec", "apps", "browser_use", "computer_use", "in_app_browser", "hooks", "memories", "plugins"] {
                arguments += ["--disable", feature]
            }
            arguments += ["-C", folder.path]
            if !model.isEmpty { arguments += ["-m", model] }
            if let reasoning { arguments += ["-c", "model_reasoning_effort=\"\(reasoning.rawValue)\""] }
            arguments.append("-")
            return arguments
        case .copilot:
            // An empty --available-tools leaves every tool; one that names no tool leaves none.
            var arguments = [
                "-C", folder.path, "--output-format", "json", "--no-color",
                "--available-tools=takku_none", "--no-custom-instructions", "--disable-builtin-mcps",
                "--no-ask-user", "--no-remote-export", "--no-auto-update", "--disable-client-telemetry",
            ]
            // "auto", the model without one, refuses any reasoning level.
            if !model.isEmpty {
                arguments += ["--model", model]
                if let reasoning { arguments += ["--reasoning-effort", reasoning.rawValue] }
            }
            return arguments
        }
    }

    /// What the run needs in its environment. Copilot keeps sessions, settings, plugins and MCP
    /// servers in its home: it gets an empty one, in `folder`'s parent, and its sign-in (in the
    /// Keychain) still works.
    public func environment(folder: URL) -> [String: String] {
        switch self {
        case .codex: [:]
        case .copilot: ["COPILOT_HOME": folder.deletingLastPathComponent().appending(path: "copilot-home").path]
        }
    }

    /// Where the CLI usually is: a Mac app does not get the PATH of the user's shell.
    public func candidatePaths(home: URL) -> [String] {
        ["/opt/homebrew/bin/\(command)", "/usr/local/bin/\(command)"]
            + [".local/bin", ".npm-global/bin", ".bun/bin", ".volta/bin"].map { home.appending(path: "\($0)/\(command)").path }
    }

    /// What a run ended with, read from its events.
    public struct Outcome: Equatable, Sendable {
        /// The last message the agent wrote, `nil` if none.
        public var reply: String?
        /// Why the run failed, in the provider's words; `nil` if it did not.
        public var failure: String?
        /// What the run used, for the log: tokens for Codex, premium requests for Copilot.
        public var usage = ""
        /// Commands, file reads and other tools the agent tried despite having none.
        public var toolCalls = 0

        public init(reply: String? = nil, failure: String? = nil) {
            self.reply = reply
            self.failure = failure
        }
    }

    public func outcome(ofEvents data: Data) -> Outcome {
        var outcome = Outcome()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }
            switch self {
            case .codex: Self.readCodex(type, event, into: &outcome)
            case .copilot: Self.readCopilot(type, event, into: &outcome)
            }
        }
        return outcome
    }

    private static func readCodex(_ type: String, _ event: [String: Any], into outcome: inout Outcome) {
        switch type {
        case "item.completed":
            guard let item = event["item"] as? [String: Any], let kind = item["type"] as? String else { return }
            if kind == "agent_message", let text = item["text"] as? String {
                outcome.reply = text
            } else if !["error", "reasoning"].contains(kind) {
                outcome.toolCalls += 1
            }
        case "turn.completed":
            let usage = event["usage"] as? [String: Any]
            outcome.usage = "\(usage?["input_tokens"] as? Int ?? 0) tokens in, \(usage?["output_tokens"] as? Int ?? 0) out"
        case "turn.failed":
            outcome.failure = message((event["error"] as? [String: Any])?["message"] as? String)
        case "error":
            outcome.failure = outcome.failure ?? message(event["message"] as? String)
        default:
            return
        }
    }

    private static func readCopilot(_ type: String, _ event: [String: Any], into outcome: inout Outcome) {
        let data = event["data"] as? [String: Any]
        switch type {
        case "assistant.message":
            outcome.toolCalls += (data?["toolRequests"] as? [Any])?.count ?? 0
            // A message that only asks for a tool has no text.
            if let text = data?["content"] as? String, !text.isEmpty { outcome.reply = text }
        case "session.error":
            outcome.failure = message(data?["message"] as? String)
        case "result":
            let requests = (event["usage"] as? [String: Any])?["premiumRequests"] as? Double ?? 0
            outcome.usage = "\(requests.formatted()) premium requests"
            if let code = event["exitCode"] as? Int, code != 0, outcome.failure == nil { outcome.failure = "exit \(code)" }
        default:
            return
        }
    }

    /// The provider's error is often JSON in a string: its innermost message.
    private static func message(_ text: String?) -> String? {
        guard let text else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return text }
        let error = object["error"] as? [String: Any]
        return error?["message"] as? String ?? object["message"] as? String ?? text
    }

    /// What goes to the CLI's standard input for a Chat Completions request. The CLI is a coding
    /// agent: it is told to answer with the text alone, then gets Takku's instructions and the request.
    public static func input(fromRequestBody body: Data) throws -> String {
        let (instructions, prompt) = try AppleIntelligence.conversation(fromRequestBody: body)
        return """
            You are not working on code now. Do not run commands, read files or use any tool: \
            reply only with the text the instructions below ask for, nothing before or after it.

            <instructions>
            \(instructions)
            </instructions>

            <request>
            \(prompt)
            </request>
            """
    }

    /// A Chat Completions reply holding the agent's last message.
    public func responseBody(_ text: String) -> Data {
        let body: [String: Any] = [
            "object": "chat.completion",
            "model": name,
            "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }
}

extension ProviderProfile {
    /// The agent CLI the Profile runs, `nil` for any other Provider.
    public var agentCLI: AgentCLI? { AgentCLI.allCases.first { $0.baseURL == baseURL } }
}
