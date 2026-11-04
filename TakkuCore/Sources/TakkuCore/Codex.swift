import Foundation

/// OpenAI's Codex CLI, installed and signed in by the user, as a Provider: the Summary is paid by
/// their ChatGPT plan (or by the API key they signed in with), and Takku holds no key. Like Apple
/// Intelligence, its Profile goes through `ChatClient`, whose transport hands each Chat
/// Completions request to `codex exec` instead of the network and answers in the same format, so
/// Summaries in blocks, the title and the Summary log work as with any Provider. Codex sends the
/// text to OpenAI: it does not run on this Mac.
public enum Codex {
    /// Not an address: it marks the Profile, and the transport never sends it anywhere.
    public static let baseURL = "codex://this-mac"
    public static let name = "Codex"
    /// What Codex's models take comfortably, after its own instructions (about 15,000 tokens).
    public static let contextTokens = 128_000

    /// A Profile for Codex. An empty model is the one Codex picks.
    public static func profile() -> ProviderProfile {
        ProviderProfile(name: name, baseURL: baseURL, model: "", maxContextTokens: contextTokens, reasoning: .low)
    }

    /// The arguments for `codex exec`, which reads the prompt from standard input and writes its
    /// events as JSON lines (see `Outcome`). One run per request, with nothing of the user's coding
    /// setup: no session saved, no config.toml (its MCP servers and instructions; the sign-in
    /// stays), no rules, no AGENTS.md, a read-only sandbox in an empty folder.
    public static func arguments(model: String, reasoning: ProviderProfile.ReasoningEffort?, folder: URL) -> [String] {
        var arguments = [
            "exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
            "--sandbox", "read-only", "--color", "never", "--json",
            "-c", "project_doc_max_bytes=0",
            "-C", folder.path,
        ]
        let model = model.trimmingCharacters(in: .whitespaces)
        if !model.isEmpty { arguments += ["-m", model] }
        // Codex's models take none, low, medium and high as Takku names them.
        if let reasoning { arguments += ["-c", "model_reasoning_effort=\"\(reasoning.rawValue)\""] }
        arguments.append("-")
        return arguments
    }

    /// What a run of `codex exec --json` ended with, read from its events.
    public struct Outcome: Equatable, Sendable {
        /// The last message Codex wrote, `nil` if none.
        public var reply: String?
        /// Why the turn failed, in the provider's words; `nil` if it did not.
        public var failure: String?
        public var inputTokens = 0
        public var outputTokens = 0
        /// Commands, file reads and other tools Codex used despite being told not to.
        public var toolCalls = 0

        public init(reply: String? = nil, failure: String? = nil) {
            self.reply = reply
            self.failure = failure
        }
    }

    public static func outcome(ofEvents data: Data) -> Outcome {
        var outcome = Outcome()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }
            switch type {
            case "item.completed":
                guard let item = event["item"] as? [String: Any], let kind = item["type"] as? String else { continue }
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
                continue
            }
        }
        return outcome
    }

    /// The provider's error is often JSON in a string: its innermost message.
    private static func message(_ text: String?) -> String? {
        guard let text else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return text }
        let error = object["error"] as? [String: Any]
        return error?["message"] as? String ?? object["message"] as? String ?? text
    }

    /// What goes to Codex's standard input for a Chat Completions request. Codex is a coding agent:
    /// it is told to answer with the text alone, then gets Takku's instructions and the request.
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

    /// A Chat Completions reply holding Codex's last message.
    public static func responseBody(_ text: String) -> Data {
        let body: [String: Any] = [
            "object": "chat.completion",
            "model": name,
            "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// Where Codex usually is: a Mac app does not get the PATH of the user's shell.
    public static func candidatePaths(home: URL) -> [String] {
        ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            + [".local/bin/codex", ".npm-global/bin/codex", ".bun/bin/codex", ".volta/bin/codex"]
            .map { home.appending(path: $0).path }
    }
}

extension ProviderProfile {
    public var isCodex: Bool { baseURL == Codex.baseURL }
}
