import Foundation

/// A coding agent's CLI, installed and signed in by the user, as a Provider: the Summary is paid by
/// their plan, and Takku holds no key and signs in to nothing (ADR 0017). Like Apple Intelligence,
/// its Profile goes through `ChatClient`, whose transport hands each Chat Completions request to
/// one run of the CLI (see `Runner`) and answers in the same format, so Summaries in blocks, the
/// title and the Summary log work as with any Provider. The CLI sends the text to its provider:
/// it does not run on this Mac.
///
/// A run has nothing of the user's coding setup and no tools: no session kept (OpenCode's is
/// deleted after it, Antigravity's goes with the home it ran in), no settings, instructions, MCP
/// servers, hooks, memories, plugins or skills, no API key from the environment, in an empty folder.
public enum AgentCLI: String, CaseIterable, Sendable {
    case codex, copilot, claude, opencode, pi, antigravity

    public var name: String {
        switch self {
        case .codex: "Codex"
        case .copilot: "GitHub Copilot"
        case .claude: "Claude Code"
        case .opencode: "OpenCode"
        case .pi: "Pi"
        case .antigravity: "Antigravity"
        }
    }

    var command: String { self == .antigravity ? "agy" : rawValue }

    /// Not an address: it marks the Profile, and the transport never sends it anywhere.
    public var baseURL: String { "\(rawValue)://this-mac" }

    /// What installs the CLI, for a user who does not have it.
    var installCommand: String {
        switch self {
        case .codex: "brew install codex"
        case .copilot: "brew install --cask copilot-cli"
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .opencode: "curl -fsSL https://opencode.ai/install | bash"
        case .pi: "npm install -g @earendil-works/pi-coding-agent"
        case .antigravity: "curl -fsSL https://antigravity.google/cli/install.sh | bash"
        }
    }

    /// What signs the user in, in Terminal.
    var signInCommand: String {
        switch self {
        case .codex: "codex login"
        case .copilot: "copilot login"
        case .claude: "claude auth login"
        case .opencode: "opencode auth login"
        case .pi: "pi"
        // It signs in when started with no arguments.
        case .antigravity: "agy"
        }
    }

    /// What the agents' models take comfortably, after their own instructions.
    static let contextTokens = 128_000

    /// A new Profile: light on the plan and quick (Codex refuses no reasoning at all, Copilot's
    /// own model refuses any level, OpenCode has none, Antigravity's default model has no Off and
    /// is at High unless told).
    public func profile() -> ProviderProfile {
        let reasoning: ProviderProfile.ReasoningEffort? = switch self {
        case .codex, .antigravity: .low
        case .claude, .pi: .off
        case .copilot, .opencode: nil
        }
        return ProviderProfile(name: name, baseURL: baseURL, model: "", maxContextTokens: Self.contextTokens, reasoning: reasoning)
    }

    // MARK: - Models

    /// A model the agent offers, and the reasoning levels it accepts (`nil` when not known).
    public struct Model: Codable, Hashable, Sendable {
        public var name: String
        public var reasoning: [ProviderProfile.ReasoningEffort]?

        public init(_ name: String, reasoning: [ProviderProfile.ReasoningEffort]? = nil) {
            self.name = name
            self.reasoning = reasoning
        }
    }

    /// Whether the agent picks a model when the Profile names none. OpenCode and Pi, apart from
    /// the user's settings, have no default of their own.
    public var hasDefaultModel: Bool { self != .opencode && self != .pi }

    /// The models that need no run to list. Claude Code has no list, and its aliases lag behind
    /// (2.1.282 maps haiku to Haiku 4.5): the latest full names, to update when models come out.
    public var fixedModels: [Model]? {
        switch self {
        case .claude: ["claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"].map { Model($0) }
        case .codex, .copilot, .opencode, .pi, .antigravity: nil
        }
    }

    /// The arguments that list the models, for the agents whose list depends on the user. Copilot
    /// has no such command: a run with a model no one has stops before any request, and its debug
    /// log holds the catalog it fetched for the user's plan.
    func modelListArguments(folder: URL) -> [String]? {
        switch self {
        case .codex: ["debug", "models"]
        case .copilot: arguments(model: Self.noModel, reasoning: nil, folder: folder) + ["--log-level", "all"]
        case .opencode: ["models", "--standalone"]
        case .pi: ["--list-models", "--offline"]
        case .antigravity: ["models"]
        case .claude: nil
        }
    }

    private static let noModel = "takku-lists-models"

    /// What lists the models, from what the listing run left: its output, or Copilot's log.
    func modelListing(output: Data, status: Int32, scratch: URL) -> Data? {
        guard self == .copilot else { return status == 0 ? output : nil }
        let logs = scratch.appending(path: "home/logs")
        let files = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "log" }.compactMap { try? Data(contentsOf: $0) }.reduce(Data(), +)
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
        case .pi:
            // A table: provider, model, then the model's limits.
            return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { row in
                let columns = row.split(whereSeparator: \.isWhitespace)
                guard columns.count >= 2, columns[0] != "provider" else { return nil }
                return Model("\(columns[0])/\(columns[1])")
            }
        case .copilot:
            // The chat models the user's plan or organisation turned on; auto is the menu's Default.
            let catalog = String(decoding: data, as: UTF8.self).split(separator: "\n").last { $0.contains("fetched model catalog") }
            guard let catalog, let brace = catalog.firstIndex(of: "{"),
                  let entry = (try? JSONSerialization.jsonObject(with: Data(catalog[brace...].utf8))) as? [String: Any],
                  let listed = entry["models"] as? String,
                  let models = (try? JSONSerialization.jsonObject(with: Data(listed.utf8))) as? [[String: Any]]
            else { return [] }
            return models.compactMap { model -> Model? in
                guard (model["policy"] as? [String: Any])?["state"] as? String == "enabled",
                      (model["capabilities"] as? [String: Any])?["type"] as? String == "chat"
                else { return nil }
                return (model["id"] as? String).map { Model($0) }
            }
        case .antigravity:
            // `id<tab>display name`, one per line, one for each model and level (gemini-4-neon-high):
            // the model once, with its levels. Orchestrators plan and hand the work to other models.
            var models: [Model] = []
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let id = line.split(separator: "\t").first.map({ $0.trimmingCharacters(in: .whitespaces) }),
                      line.contains("\t"), !id.isEmpty, !id.contains(" "), !id.contains("orchestrator")
                else { continue }
                let (name, level) = Self.antigravityLevel(in: id)
                if let index = models.firstIndex(where: { $0.name == name }) {
                    if let level { models[index].reasoning = (models[index].reasoning ?? []) + [level] }
                } else {
                    models.append(Model(name, reasoning: level.map { [$0] } ?? []))
                }
            }
            let order = ProviderProfile.ReasoningEffort.allCases
            return models.map { model in Model(model.name, reasoning: order.filter { (model.reasoning ?? []).contains($0) }) }
        case .claude:
            return []
        }
    }

    /// Antigravity names a model with its level (`gemini-3.8-flash-low`) and takes it without
    /// (`gemini-3.8-flash` and `--effort low`): the name and the level Takku knows, `nil` without
    /// one. xhigh and max, which Takku does not offer, stay part of the name.
    static func antigravityLevel(in id: String) -> (name: String, level: ProviderProfile.ReasoningEffort?) {
        for level in [ProviderProfile.ReasoningEffort.low, .medium, .high] where id.hasSuffix("-\(level.rawValue)") {
            return (String(id.dropLast(level.rawValue.count + 1)), level)
        }
        return (id, nil)
    }

    /// Whether an Antigravity model's name has a level, any level: it then takes none apart.
    static func antigravityNamesLevel(_ model: String) -> Bool {
        ["low", "medium", "high", "xhigh", "max"].contains { model.hasSuffix("-\($0)") }
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
        case .claude, .pi:
            return all
        case .codex:
            let model = model.trimmingCharacters(in: .whitespaces)
            let known = (models ?? []).compactMap(\.reasoning)
            if model.isEmpty, !known.isEmpty {
                // The default model is not named: the levels every model accepts.
                return all.filter { level in known.allSatisfy { $0.contains(level) } }
            }
            return models?.first { $0.name == model }?.reasoning.map { levels in all.filter(levels.contains) } ?? all
        case .antigravity:
            // No Off. Its default model has Low, Medium and High; a level in the name leaves none.
            let model = model.trimmingCharacters(in: .whitespaces)
            let levels: [ProviderProfile.ReasoningEffort] = [.low, .medium, .high]
            if model.isEmpty { return levels }
            if Self.antigravityNamesLevel(model) { return [] }
            return models?.first { $0.name == model }?.reasoning ?? levels
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
    private var replacesSystemPrompt: Bool { self == .claude || self == .opencode || self == .pi || self == .antigravity }

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

    /// What the run reads from its standard input: the input as it is, or for Antigravity, which
    /// reads a prompt from standard input only as JSON, one message.
    func standardInput(_ input: String) -> Data {
        guard self == .antigravity else { return Data(input.utf8) }
        let message: [String: Any] = ["event": "user", "message": ["role": "user", "content": input]]
        return ((try? JSONSerialization.data(withJSONObject: message)) ?? Data()) + Data("\n".utf8)
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
                // The denylist below names features, not every tool: web search is a setting of its own.
                "-c", "web_search=\"disabled\"",
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
        case .pi:
            // Its settings file stays (it holds the default model and level, both always given here).
            var arguments = [
                "-p", "--mode", "json", "--no-session", "--no-tools", "--no-extensions", "--no-skills",
                "--no-prompt-templates", "--no-themes", "--no-context-files", "--no-approve", "--offline",
                "--system-prompt", Self.systemPrompt,
            ]
            if !model.isEmpty { arguments += ["--model", model] }
            if let reasoning { arguments += ["--thinking", reasoning == .off ? "off" : reasoning.rawValue] }
            return arguments
        case .antigravity:
            // Its tools go with Takku's agent (see `prepare`); the denials only back that up: any
            // tool left would ask, and a run that cannot ask is refused it.
            var arguments = [
                "--input-format", "stream-json", "--output-format", "stream-json", "--agent", Self.antigravityAgent,
                "--disable-slash-commands", "--settings", Self.antigravitySettings,
            ]
            if !model.isEmpty { arguments += ["--model", model] }
            // A level in the model's name and one given apart are refused together.
            if let reasoning, reasoning != .off, !Self.antigravityNamesLevel(model) {
                arguments += ["--effort", reasoning.rawValue]
            }
            // Print mode with no prompt of its own: it reads it from standard input.
            arguments.append("-p=")
            return arguments
        }
    }

    /// Takku's agent for Antigravity's runs, which gives the model no tools and Takku's system prompt.
    static let antigravityAgent = "takku"

    static let antigravitySettings: String = {
        let settings: [String: Any] = [
            "toolPermission": "strict",
            "permissions": ["deny": ["read_file(*)", "write_file(*)", "read_url(*)", "execute_url(*)", "command(*)", "mcp(*)"]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: settings, options: .sortedKeys)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }()

    /// The title of OpenCode's sessions of Takku's runs, which marks them for deletion.
    static let openCodeTitle = "Takku"

    /// What the run needs in its environment, in `scratch`, deleted after it. Copilot keeps its
    /// setup in its home (its sign-in stays in the Keychain); OpenCode gets an agent of Takku's
    /// with every tool denied, no config of the user's, and keeps its sign-in database.
    /// Antigravity has no folder of its own to move: it gets an empty home (see `prepare`), where
    /// it keeps its conversation, so nothing of the user's `~/.gemini` and `~/.agents` is read
    /// (rules, skills, hooks, MCP servers, plugins) and nothing is written there.
    func environment(scratch: URL) -> [String: String] {
        switch self {
        case .antigravity:
            // Its updater would otherwise start in the background, in a home about to go.
            return ["HOME": scratch.appending(path: "home").path, "AGY_CLI_DISABLE_AUTO_UPDATE": "true"]
        case .codex, .claude:
            return [:]
        case .copilot:
            return ["COPILOT_HOME": scratch.appending(path: "home").path]
        case .pi:
            return ["PI_TELEMETRY": "0"]
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

    /// Copilot's empty home needs to know who is signed in (its token stays in the Keychain):
    /// without it Copilot runs on the free tier. Only that is copied from the user's settings.
    /// Antigravity's empty home gets the way to the user's Keychains, where its sign-in is (macOS
    /// finds them from the home), and Takku's agent.
    func prepare(scratch: URL, environment: [String: String]) {
        if self == .antigravity {
            prepareAntigravity(home: scratch.appending(path: "home"), environment: environment)
            prepareCommands(scratch: scratch)
        }
        guard self == .copilot, let account = Self.copilotAccount(environment: environment),
              let data = try? JSONSerialization.data(withJSONObject: account)
        else { return }
        try? data.write(to: scratch.appending(path: "home/config.json"))
    }

    /// A folder put first on the run's PATH, `nil` when the CLI needs none. Antigravity, signed
    /// out (its sign-in expired between the check and the run), opens a Google sign-in page in the
    /// browser with `open`: there it finds one that does nothing, and the run fails as not signed in.
    func commandsFolder(scratch: URL) -> URL? {
        self == .antigravity ? scratch.appending(path: "bin") : nil
    }

    private func prepareCommands(scratch: URL) {
        guard let folder = commandsFolder(scratch: scratch) else { return }
        let open = folder.appending(path: "open")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? "#!/bin/sh\nexit 0\n".write(to: open, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)
    }

    private func prepareAntigravity(home: URL, environment: [String: String]) {
        let fileManager = FileManager.default
        let userHome = URL(filePath: environment["HOME"] ?? NSHomeDirectory())
        let library = home.appending(path: "Library"), agents = home.appending(path: ".gemini/config/agents")
        try? fileManager.createDirectory(at: library, withIntermediateDirectories: true)
        try? fileManager.createSymbolicLink(at: library.appending(path: "Keychains"), withDestinationURL: userHome.appending(path: "Library/Keychains"))
        try? fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
        // An empty tool list leaves the model none (but its own task list); the text replaces its system prompt.
        let agent = """
            ---
            name: \(Self.antigravityAgent)
            description: Writes text only
            tools: []
            mainAgent: true
            subagent: false
            ---
            \(Self.systemPrompt)

            """
        try? agent.write(to: agents.appending(path: "\(Self.antigravityAgent).md"), atomically: true, encoding: .utf8)
    }

    /// Who is signed in to Copilot, from its settings file: `loggedInUsers` and `lastLoggedInUser`,
    /// `nil` when no one is. Copilot has no command that says it, and a run without this has no
    /// sign-in whatever the Keychain holds.
    static func copilotAccount(environment: [String: String]) -> [String: Any]? {
        let home = environment["COPILOT_HOME"].map { URL(filePath: $0) }
            ?? URL(filePath: environment["HOME"] ?? NSHomeDirectory()).appending(path: ".copilot")
        guard let text = try? String(contentsOf: home.appending(path: "config.json"), encoding: .utf8) else { return nil }
        // The file opens with // comments.
        let json = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        guard let config = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let users = config["loggedInUsers"] as? [Any], !users.isEmpty
        else { return nil }
        return config.filter { ["loggedInUsers", "lastLoggedInUser"].contains($0.key) }
    }

    /// The agents that can write the Summary with one click, in the order of `allCases`: installed,
    /// signed in as far as can be told without a run, and with a model of their own (OpenCode and
    /// Pi need one chosen in the Profile). Checked all at once.
    public static func ready(among runners: [Runner]) async -> [AgentCLI] {
        let found = await withTaskGroup(of: AgentCLI?.self) { group in
            for runner in runners where runner.cli.hasDefaultModel {
                group.addTask { await runner.unavailability() == nil ? runner.cli : nil }
            }
            return await group.reduce(into: Set<AgentCLI>()) { if let cli = $1 { $0.insert(cli) } }
        }
        return allCases.filter(found.contains)
    }

    /// The variables no run gets: with an API key the CLI bills per token instead of using the plan
    /// (Claude Code always does under `-p`), and an agent's own variables would bring back the
    /// session it runs in or settings of the user's.
    static func isRemoved(_ variable: String) -> Bool {
        // Where the user moved an agent's sign-in: without it the CLI would be signed out.
        if ["CODEX_HOME", "PI_CODING_AGENT_DIR"].contains(variable) { return false }
        return variable.hasSuffix("_API_KEY") || variable.hasSuffix("_TOKEN")
            || ["ANTHROPIC_", "CLAUDE", "OPENCODE_", "CODEX_", "COPILOT_", "PI_", "AWS_", "AZURE_OPENAI_", "AGY_", "ANTIGRAVITY_", "GEMINI_"]
                .contains { variable.hasPrefix($0) }
    }

    // MARK: - What a run ended with

    struct Outcome {
        /// The last message the agent wrote, `nil` if none.
        var reply: String?
        /// Why the run failed, in the provider's words; `nil` if it did not.
        var failure: String?
        var inputTokens = 0, outputTokens = 0
        /// What a Copilot run used instead of tokens.
        var premiumRequests: Double?
        /// Commands, file reads and other tools the agent tried despite having none.
        var toolCalls = 0
        /// The model that answered, as the agent reports it (Copilot's auto picks one); `nil` if it does not.
        var model: String?
        /// OpenCode's session, to delete.
        var session: String?
        /// The steps of an Antigravity run that were tools, each reported more than once.
        var toolSteps: Set<Int> = []

        /// What the run used, for the log; empty if the agent did not say.
        var usage: String {
            if let premiumRequests { return "\(premiumRequests.formatted()) premium requests" }
            return inputTokens + outputTokens > 0 ? "\(inputTokens) tokens in, \(outputTokens) out" : ""
        }
    }

    func outcome(ofEvents data: Data) -> Outcome {
        var outcome = Outcome()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // Antigravity names it `event`.
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = event["type"] as? String ?? event["event"] as? String
            else { continue }
            switch self {
            case .codex: Self.readCodex(type, event, into: &outcome)
            case .copilot: Self.readCopilot(type, event, into: &outcome)
            case .claude: Self.readClaude(type, event, into: &outcome)
            case .opencode: Self.readOpenCode(type, event, into: &outcome)
            case .pi: Self.readPi(type, event, into: &outcome)
            case .antigravity: Self.readAntigravity(type, event, into: &outcome)
            }
        }
        return outcome
    }

    /// What it prints before an event, or instead of any: the line that says why, the first for Pi
    /// and Antigravity (which list their options after it) and the last for the others. A usage
    /// line and a hint to `--help` follow the error and say nothing about it ("For more information, try '--help'.", "Try 'copilot --help' for more
    /// information."), so they are left out.
    func reason(inPrinted text: String) -> String? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            !$0.isEmpty && !$0.lowercased().hasPrefix("usage:") && !$0.contains("--help")
        }
        return (self == .pi || self == .antigravity ? lines.first : lines.last)
    }

    /// Whether the CLI refused one of the options Takku runs it with: it is older than Takku, or
    /// changed under it (ADR 0017).
    static func isUnknownOption(_ reason: String) -> Bool {
        // Antigravity: "flags provided but not defined", and "unknown setting" for one in `--settings`.
        [
            "unexpected argument", "unknown option", "unknown argument", "unrecognized option", "unrecognized argument",
            "provided but not defined", "unknown setting",
        ]
            .contains { reason.localizedCaseInsensitiveContains($0) }
    }

    /// Exits with 0 also when the provider failed, after its own retries: the last message says so.
    private static func readPi(_ type: String, _ event: [String: Any], into outcome: inout Outcome) {
        guard type == "message_end", let message = event["message"] as? [String: Any], message["role"] as? String == "assistant" else { return }
        let content = message["content"] as? [[String: Any]] ?? []
        outcome.toolCalls += content.filter { $0["type"] as? String == "toolCall" }.count
        let usage = message["usage"] as? [String: Any]
        outcome.inputTokens += usage?["input"] as? Int ?? 0
        outcome.outputTokens += usage?["output"] as? Int ?? 0
        if let provider = message["provider"] as? String, let model = message["model"] as? String { outcome.model = "\(provider)/\(model)" }
        if message["stopReason"] as? String == "error" {
            outcome.failure = message["errorMessage"] as? String ?? "error"
            return
        }
        let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        if !text.isEmpty {
            outcome.reply = text
            outcome.failure = nil
        }
    }

    /// The model only when the Profile names one; the reply and why it failed in the result, which
    /// says `SUCCESS` also after a retry that worked.
    private static func readAntigravity(_ type: String, _ event: [String: Any], into outcome: inout Outcome) {
        switch type {
        case "init":
            outcome.model = (event["init"] as? [String: Any])?["model"] as? String
        case "step_update":
            guard let step = event["step_update"] as? [String: Any], step["step_type"] as? String == "tool",
                  let index = step["step_index"] as? Int
            else { return }
            outcome.toolSteps.insert(index)
            outcome.toolCalls = outcome.toolSteps.count
        case "result":
            guard let result = event["result"] as? [String: Any] else { return }
            let usage = result["usage"] as? [String: Any]
            outcome.inputTokens += usage?["input_tokens"] as? Int ?? 0
            outcome.outputTokens += usage?["output_tokens"] as? Int ?? 0
            if result["status"] as? String == "SUCCESS" {
                outcome.reply = result["response"] as? String
            } else {
                // An unknown model's error goes on to list every model: its first line.
                let error = (result["error"] as? String)?.split(separator: "\n").first.map(String.init)
                outcome.failure = message(error) ?? result["status"] as? String ?? "error"
            }
        default:
            return
        }
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
            outcome.inputTokens += usage?["input_tokens"] as? Int ?? 0
            outcome.outputTokens += usage?["output_tokens"] as? Int ?? 0
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
        case "session.auto_mode_resolved":
            outcome.model = data?["chosenModel"] as? String
        case "assistant.message":
            outcome.toolCalls += (data?["toolRequests"] as? [Any])?.count ?? 0
            // A message that only asks for a tool has no text.
            if let text = data?["content"] as? String, !text.isEmpty { outcome.reply = text }
        case "session.error":
            outcome.failure = message(data?["message"] as? String)
        case "result":
            outcome.premiumRequests = (event["usage"] as? [String: Any])?["premiumRequests"] as? Double ?? 0
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
        for key in ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] {
            outcome.inputTokens += usage?[key] as? Int ?? 0
        }
        outcome.outputTokens += usage?["output_tokens"] as? Int ?? 0
        outcome.toolCalls += (event["permission_denials"] as? [Any])?.count ?? 0
        outcome.model = (event["modelUsage"] as? [String: Any])?.keys.sorted().joined(separator: ", ")
    }

    private static func readOpenCode(_ type: String, _ event: [String: Any], into outcome: inout Outcome) {
        outcome.session = outcome.session ?? event["sessionID"] as? String
        let part = event["part"] as? [String: Any]
        switch type {
        case "text":
            if let text = part?["text"] as? String, !text.isEmpty { outcome.reply = text }
        case "step_finish":
            let used = part?["tokens"] as? [String: Any]
            outcome.inputTokens += used?["input"] as? Int ?? 0
            outcome.outputTokens += used?["output"] as? Int ?? 0
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

    /// The arguments that tell whether the CLI is signed in; Copilot and Pi have none (Copilot's
    /// settings file says it, see `copilotAccount`; Pi signs in per provider).
    var signInCheckArguments: [String]? {
        switch self {
        case .codex: ["login", "status"]
        case .claude: ["auth", "status"]
        // Standalone: with its state moved, the background service would clash with the user's.
        case .opencode: ["auth", "list", "--standalone", "--format", "json"]
        // Signed out, it says so and ends; a run would wait a minute for a sign-in in the browser.
        case .antigravity: ["models"]
        case .copilot, .pi: nil
        }
    }

    /// Whether the sign-in check says signed in. OpenCode lists the Providers signed in to without
    /// checking them: none means none. Antigravity's check fails also offline: only its request to
    /// sign in, which it prints as an error, means signed out.
    func isSignedIn(status: Int32, output: Data, errors: Data = Data()) -> Bool {
        if self == .antigravity {
            return status == 0 || !String(decoding: output + errors, as: UTF8.self).localizedCaseInsensitiveContains("sign in")
        }
        guard status == 0 else { return false }
        let object = try? JSONSerialization.jsonObject(with: output)
        switch self {
        case .claude: return (object as? [String: Any])?["loggedIn"] as? Bool != false
        case .opencode: return (object as? [Any])?.isEmpty == false
        case .codex, .copilot, .pi, .antigravity: return true
        }
    }

    /// The sessions of Takku's runs in an OpenCode session list: those with its title, in `folder`,
    /// created before `date`. Never another of the user's.
    func leftoverSessions(inListing data: Data, folder: URL, createdBefore date: Date) -> [String] {
        let sessions = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        let folder = folder.resolvingSymlinksInPath().path
        return sessions.compactMap { session in
            guard session["title"] as? String == Self.openCodeTitle,
                  let directory = session["directory"] as? String,
                  URL(filePath: directory).resolvingSymlinksInPath().path == folder,
                  let created = session["created"] as? Double, created / 1000 < date.timeIntervalSince1970
            else { return nil }
            return session["id"] as? String
        }
    }

    /// A Chat Completions reply holding the agent's last message, with what the run used for the
    /// Summary log.
    func responseBody(_ text: String, outcome: Outcome) -> Data {
        var agent: [String: Any] = ["name": name, "usage": outcome.usage, "tool_calls": outcome.toolCalls]
        agent["model"] = outcome.model
        let body: [String: Any] = [
            "object": "chat.completion",
            "model": name,
            "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
            "agent": agent,
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }
}

extension ProviderProfile {
    /// The agent CLI the Profile runs, `nil` for any other Provider.
    public var agentCLI: AgentCLI? { AgentCLI.allCases.first { $0.baseURL == baseURL } }
}
