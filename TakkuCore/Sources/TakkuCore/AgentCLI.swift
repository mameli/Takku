import Foundation

/// A coding agent's CLI, installed and signed in by the user, as a Provider: the Summary is paid by
/// their plan, and Takku holds no key and signs in to nothing (ADR 0017). Like Apple Intelligence,
/// its Profile goes through `ChatClient`, whose transport hands each Chat Completions request to
/// one run of the CLI (see `Runner`) and answers in the same format, so Summaries in blocks, the
/// title and the Summary log work as with any Provider. The CLI sends the text to its provider:
/// it does not run on this Mac.
///
/// A run has nothing of the user's coding setup and no tools: no session kept (OpenCode's is
/// deleted after it), no settings, instructions, MCP servers, hooks, memories, plugins or skills,
/// no API key from the environment, in an empty folder.
public enum AgentCLI: String, CaseIterable, Sendable {
    case codex, copilot, claude, opencode

    public var name: String {
        switch self {
        case .codex: "Codex"
        case .copilot: "GitHub Copilot"
        case .claude: "Claude Code"
        case .opencode: "OpenCode"
        }
    }

    public var command: String { rawValue }

    /// Not an address: it marks the Profile, and the transport never sends it anywhere.
    public var baseURL: String { "\(rawValue)://this-mac" }

    /// What installs the CLI, for a user who does not have it.
    public var installCommand: String {
        switch self {
        case .codex: "brew install codex"
        case .copilot: "brew install --cask copilot-cli"
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .opencode: "curl -fsSL https://opencode.ai/install | bash"
        }
    }

    /// What signs the user in, in Terminal.
    public var signInCommand: String {
        switch self {
        case .codex: "codex login"
        case .copilot: "copilot login"
        case .claude: "claude auth login"
        case .opencode: "opencode auth login"
        }
    }

    /// What the agents' models take comfortably, after their own instructions.
    public static let contextTokens = 128_000

    /// A new Profile: light on the plan and quick (Codex refuses no reasoning at all, Copilot's
    /// own model refuses any level, OpenCode has none).
    public func profile() -> ProviderProfile {
        let reasoning: ProviderProfile.ReasoningEffort? = switch self {
        case .codex: .low
        case .claude: .off
        case .copilot, .opencode: nil
        }
        return ProviderProfile(name: name, baseURL: baseURL, model: "", maxContextTokens: Self.contextTokens, reasoning: reasoning)
    }

    // MARK: - Models

    /// A model the agent offers, and the reasoning levels it accepts (`nil` when not known).
    public struct Model: Hashable, Sendable {
        public var name: String
        public var reasoning: [ProviderProfile.ReasoningEffort]?

        public init(_ name: String, reasoning: [ProviderProfile.ReasoningEffort]? = nil) {
            self.name = name
            self.reasoning = reasoning
        }
    }

    /// Whether the agent picks a model when the Profile names none. OpenCode, apart from the
    /// user's settings, has no default of its own.
    public var hasDefaultModel: Bool { self != .opencode }

    /// The models that need no run to list: Claude Code's aliases always mean the latest of each,
    /// and Copilot's plans differ, so only its own choice is sure.
    var fixedModels: [Model]? {
        switch self {
        case .claude: ["fable", "opus", "sonnet", "haiku"].map { Model($0) }
        case .copilot: [Model("auto")]
        case .codex, .opencode: nil
        }
    }

    /// The arguments that list the models, for the agents whose list depends on the user.
    var modelListArguments: [String]? {
        switch self {
        case .codex: ["debug", "models"]
        case .opencode: ["models"]
        case .copilot, .claude: nil
        }
    }

    /// The models in what `modelListArguments` printed. Codex: the ones it lists in its own
    /// picker, with their levels; OpenCode: `provider/model`, one per line.
    func models(fromListing data: Data) -> [Model] {
        switch self {
        case .codex:
            let models = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["models"] as? [[String: Any]] ?? []
            return models.compactMap { model in
                guard model["visibility"] as? String == "list", let slug = model["slug"] as? String else { return nil }
                let levels = (model["supported_reasoning_levels"] as? [[String: Any]])?
                    .compactMap { ($0["effort"] as? String).flatMap(ProviderProfile.ReasoningEffort.init) }
                return Model(slug, reasoning: levels)
            }
        case .opencode:
            return String(decoding: data, as: UTF8.self).split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.contains("/") && !$0.contains(" ") }
                .map { Model($0) }
        case .copilot, .claude:
            return []
        }
    }

    /// The reasoning levels the Profile editor offers with `model` (empty: the agent's default)
    /// among `models`: `nil` hides the choice, empty disables it.
    public func reasoningLevels(for model: String, in models: [Model]?) -> [ProviderProfile.ReasoningEffort]? {
        let all = ProviderProfile.ReasoningEffort.allCases
        switch self {
        case .opencode:
            // Its levels are variants of each model: `provider/model#variant` in the model.
            return nil
        case .copilot:
            return Self.isCopilotAuto(model) ? [] : all
        case .claude:
            return all
        case .codex:
            let model = model.trimmingCharacters(in: .whitespaces)
            let known = (models ?? []).compactMap(\.reasoning)
            if model.isEmpty, !known.isEmpty {
                // The default model is not named: the levels every model accepts.
                return all.filter { level in known.allSatisfy { $0.contains(level) } }
            }
            return models?.first { $0.name == model }?.reasoning.map { levels in all.filter(levels.contains) } ?? all
        }
    }

    /// Copilot's own choice of model, empty or named: it refuses any reasoning level.
    private static func isCopilotAuto(_ model: String) -> Bool {
        let model = model.trimmingCharacters(in: .whitespaces).lowercased()
        return model.isEmpty || model == "auto"
    }

    // MARK: - A run

    /// Takku's system prompt, where the CLI lets it replace the agent's own (which makes the model
    /// write tool calls as text even with no tools).
    static let systemPrompt = """
        You write text for Takku, an app for meeting notes. You have no tools and you are not working \
        on code: reply only with the text the instructions ask for, nothing before or after it.
        """

    /// Whether `systemPrompt` replaces the agent's own.
    private var replacesSystemPrompt: Bool { self == .claude || self == .opencode }

    /// What goes to the CLI's standard input: Takku's instructions and the request, after being
    /// told to answer with the text alone where the agent's system prompt stays.
    func input(instructions: String, prompt: String) -> String {
        let preamble = replacesSystemPrompt ? "" : """
            You are not working on code now. Do not run commands, read files or use any tool: \
            reply only with the text the instructions below ask for, nothing before or after it.


            """
        return """
            \(preamble)<instructions>
            \(instructions)
            </instructions>

            <request>
            \(prompt)
            </request>
            """
    }

    /// The arguments for one run in `folder`, empty, reading the prompt from standard input and
    /// writing its events as JSON (see `outcome(ofEvents:)`).
    func arguments(model: String, reasoning: ProviderProfile.ReasoningEffort?, folder: URL) -> [String] {
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
            if !model.isEmpty { arguments += ["--model", model] }
            if let reasoning, !Self.isCopilotAuto(model) { arguments += ["--reasoning-effort", reasoning.rawValue] }
            return arguments
        case .claude:
            // Not --bare: it ignores the plan's sign-in.
            var arguments = [
                "-p", "--output-format", "json", "--safe-mode", "--setting-sources", "", "--tools", "",
                "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
                "--system-prompt", Self.systemPrompt,
            ]
            if !model.isEmpty { arguments += ["--model", model] }
            switch reasoning {
            case .off: arguments += ["--settings", #"{"alwaysThinkingEnabled":false}"#]
            case let level?: arguments += ["--effort", level.rawValue]
            case nil: break
            }
            return arguments
        case .opencode:
            var arguments = ["run", "--standalone", "--format", "json", "--agent", "takku", "--title", Self.openCodeTitle]
            if !model.isEmpty { arguments += ["-m", model] }
            return arguments
        }
    }

    /// The title of OpenCode's sessions of Takku's runs, which marks them for deletion.
    static let openCodeTitle = "Takku"

    /// What the run needs in its environment, in `scratch`, deleted after it. Copilot keeps its
    /// setup in its home (its sign-in stays in the Keychain); OpenCode gets an agent of Takku's
    /// with every tool denied, no config of the user's, and keeps its sign-in database.
    func environment(scratch: URL) -> [String: String] {
        switch self {
        case .codex, .claude:
            return [:]
        case .copilot:
            return ["COPILOT_HOME": scratch.appending(path: "home").path]
        case .opencode:
            // Deny-all alone still offers the skill tool: its plugins go too.
            let config: [String: Any] = [
                "plugins": ["-opencode.tool.skill", "-opencode.skill"],
                "agents": ["takku": [
                    "mode": "primary", "description": "Writes text only", "system": Self.systemPrompt,
                    "permissions": [["action": "*", "resource": "*", "effect": "deny"]],
                ]],
            ]
            let content = (try? JSONSerialization.data(withJSONObject: config, options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) }
            return [
                "OPENCODE_CONFIG_DIR": scratch.appending(path: "config").path,
                "OPENCODE_CONFIG_CONTENT": content ?? "{}",
                "OPENCODE_DISABLE_PROJECT_CONFIG": "1",
                "OPENCODE_DISABLE_CLAUDE_CODE": "1",
                "OPENCODE_DISABLE_AUTOUPDATE": "1",
                "XDG_STATE_HOME": scratch.appending(path: "state").path,
                "XDG_CACHE_HOME": scratch.appending(path: "cache").path,
            ]
        }
    }

    /// The variables no run gets: with an API key the CLI bills per token instead of using the plan
    /// (Claude Code always does under `-p`), and an agent's own variables would bring back the
    /// session it runs in or settings of the user's.
    static func isRemoved(_ variable: String) -> Bool {
        let names: Set = ["OPENAI_API_KEY", "CODEX_API_KEY", "GITHUB_TOKEN", "GH_TOKEN", "COPILOT_GITHUB_TOKEN", "OPENROUTER_API_KEY"]
        return names.contains(variable) || variable.hasSuffix("_API_KEY")
            || ["ANTHROPIC_", "CLAUDE", "OPENCODE_"].contains { variable.hasPrefix($0) }
    }

    // MARK: - What a run ended with

    public struct Outcome: Equatable, Sendable {
        /// The last message the agent wrote, `nil` if none.
        public var reply: String?
        /// Why the run failed, in the provider's words; `nil` if it did not.
        public var failure: String?
        /// What the run used, for the log: tokens, or premium requests for Copilot.
        public var usage = ""
        /// Commands, file reads and other tools the agent tried despite having none.
        public var toolCalls = 0
        /// OpenCode's session, to delete.
        public var session: String?
    }

    func outcome(ofEvents data: Data) -> Outcome {
        var outcome = Outcome()
        var tokens = (input: 0, output: 0)
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }
            switch self {
            case .codex: Self.readCodex(type, event, into: &outcome)
            case .copilot: Self.readCopilot(type, event, into: &outcome)
            case .claude: Self.readClaude(type, event, into: &outcome)
            case .opencode: Self.readOpenCode(type, event, into: &outcome, tokens: &tokens)
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

    /// One JSON object; `subtype` says "success" even when `is_error` is true.
    private static func readClaude(_ type: String, _ event: [String: Any], into outcome: inout Outcome) {
        guard type == "result" else { return }
        let text = event["result"] as? String
        if event["is_error"] as? Bool == true {
            outcome.failure = text ?? "error"
        } else {
            outcome.reply = text
        }
        let usage = event["usage"] as? [String: Any]
        outcome.usage = "\(usage?["input_tokens"] as? Int ?? 0) tokens in, \(usage?["output_tokens"] as? Int ?? 0) out"
        outcome.toolCalls += (event["permission_denials"] as? [Any])?.count ?? 0
    }

    private static func readOpenCode(_ type: String, _ event: [String: Any], into outcome: inout Outcome, tokens: inout (input: Int, output: Int)) {
        outcome.session = outcome.session ?? event["sessionID"] as? String
        let part = event["part"] as? [String: Any]
        switch type {
        case "text":
            if let text = part?["text"] as? String, !text.isEmpty { outcome.reply = text }
        case "step_finish":
            let used = part?["tokens"] as? [String: Any]
            tokens.input += used?["input"] as? Int ?? 0
            tokens.output += used?["output"] as? Int ?? 0
            outcome.usage = "\(tokens.input) tokens in, \(tokens.output) out"
        case "error":
            let error = event["error"] as? [String: Any]
            outcome.failure = message(error?["message"] as? String) ?? error?["type"] as? String ?? "error"
        case "step_start", "reasoning":
            return
        default:
            outcome.toolCalls += 1
        }
    }

    /// The provider's error is often JSON in a string: its innermost message.
    private static func message(_ text: String?) -> String? {
        guard let text else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return text }
        let error = object["error"] as? [String: Any]
        return error?["message"] as? String ?? object["message"] as? String ?? text
    }

    // MARK: - Sign-in and sessions

    /// The arguments that tell whether the CLI is signed in; Copilot has none (a signed-out run's
    /// error says so).
    var signInCheckArguments: [String]? {
        switch self {
        case .codex: ["login", "status"]
        case .claude: ["auth", "status"]
        case .opencode: ["auth", "list", "--format", "json"]
        case .copilot: nil
        }
    }

    /// Whether the sign-in check says signed in. OpenCode lists the Providers signed in to without
    /// checking them: none means none.
    func isSignedIn(status: Int32, output: Data) -> Bool {
        guard status == 0 else { return false }
        let object = try? JSONSerialization.jsonObject(with: output)
        switch self {
        case .claude: return (object as? [String: Any])?["loggedIn"] as? Bool != false
        case .opencode: return (object as? [Any])?.isEmpty == false
        case .codex, .copilot: return true
        }
    }

    /// The sessions of Takku's runs in an OpenCode session list: those with its title, in `folder`.
    /// Never another of the user's.
    func leftoverSessions(inListing data: Data, folder: URL) -> [String] {
        let sessions = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        let folder = folder.resolvingSymlinksInPath().path
        return sessions.compactMap { session in
            guard session["title"] as? String == Self.openCodeTitle,
                  let directory = session["directory"] as? String,
                  URL(filePath: directory).resolvingSymlinksInPath().path == folder
            else { return nil }
            return session["id"] as? String
        }
    }

    /// A Chat Completions reply holding the agent's last message, with what the run used for the
    /// Summary log.
    func responseBody(_ text: String, outcome: Outcome) -> Data {
        let body: [String: Any] = [
            "object": "chat.completion",
            "model": name,
            "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
            "agent": ["name": name, "usage": outcome.usage, "tool_calls": outcome.toolCalls],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }
}

extension ProviderProfile {
    /// The agent CLI the Profile runs, `nil` for any other Provider.
    public var agentCLI: AgentCLI? { AgentCLI.allCases.first { $0.baseURL == baseURL } }
}
