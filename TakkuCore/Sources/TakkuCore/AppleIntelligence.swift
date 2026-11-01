import Foundation

/// The model of Apple Intelligence on the Mac, through Foundation Models (macOS 26 or later). It
/// is a Provider like the others: its Profile goes through `ChatClient`, whose transport hands
/// each Chat Completions request to the model instead of the network and answers in the same
/// format, so Summaries in blocks, the title and the Summary log work as with any Provider.
/// Nothing leaves the Mac. The model is small (a few billion parameters, 4,096 tokens of context
/// on macOS 26, 8,192 on macOS 27): Summaries come in more blocks and are less rich.
public enum AppleIntelligence {
    /// Not an address: it marks the Profile, and the transport never sends it anywhere.
    public static let baseURL = "apple-intelligence://this-mac"
    public static let model = "apple-on-device"
    public static let name = "Apple Intelligence"
    /// The context of the model on macOS 26, when the system does not say.
    public static let defaultContextTokens = 4_096

    /// A Profile for the model, with the context the system reports.
    public static func profile(contextTokens: Int) -> ProviderProfile {
        ProviderProfile(name: name, baseURL: baseURL, model: model, maxContextTokens: contextTokens)
    }

    /// What a Chat Completions request asks: the system messages as the model's instructions, the
    /// others as the prompt, in order.
    public static func conversation(fromRequestBody body: Data) throws -> (instructions: String, prompt: String) {
        struct Request: Decodable { let messages: [ChatMessage] }
        let messages = try JSONDecoder().decode(Request.self, from: body).messages
        let instructions = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let prompt = messages.filter { $0.role != .system }.map(\.content).joined(separator: "\n\n")
        return (instructions, prompt)
    }

    /// The model's Markdown, fixed where it stumbles: it repeats the list marker of a nested
    /// point ("- - text", "  - - [ ] action"), which renders as an empty point holding another.
    public static func cleaned(_ reply: String) -> String {
        reply.components(separatedBy: "\n").map { line in
            guard let match = line.wholeMatch(of: /(\s*)(?:[-*] +){2,}(.*)/) else { return line }
            return "\(match.1)- \(match.2)"
        }
        .joined(separator: "\n")
    }

    /// A Chat Completions reply holding `text`.
    public static func responseBody(_ text: String) -> Data {
        let body: [String: Any] = [
            "object": "chat.completion",
            "model": model,
            "choices": [["index": 0, "message": ["role": "assistant", "content": cleaned(text)], "finish_reason": "stop"]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }
}

extension ProviderProfile {
    public var isAppleIntelligence: Bool { baseURL == AppleIntelligence.baseURL }

    /// Room left for the reply in every Summary request: Apple Intelligence's context is too small
    /// for the usual 4,096 tokens, and its replies are short, so it keeps a quarter of it.
    public var replyReserveTokens: Int {
        isAppleIntelligence ? maxContextTokens / 4 : SummaryPrompt.replyReserveTokens
    }
}
