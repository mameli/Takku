import Foundation

public struct ChatMessage: Codable, Equatable, Sendable {
    public enum Sender: String, Codable, Sendable {
        case system, user, assistant
    }

    public let role: Sender
    public let content: String

    public init(role: Sender, content: String) {
        self.role = role
        self.content = content
    }
}

/// Client for OpenAI-compatible Chat Completions and Responses APIs:
/// remote providers and local servers such as llama.cpp or Ollama (ADR 0004).
public struct ChatClient: Sendable {
    public enum Failure: LocalizedError, Equatable {
        /// The provider answered with an error: HTTP status and message as it sent them. When it
        /// refused the request (400, 422), also what the Profile added to it, which may be the cause:
        /// the reasoning level if it was sent, and whether there were Extra parameters.
        case http(
            status: Int, message: String, reasoning: ProviderProfile.ReasoningEffort? = nil, hasExtraParameters: Bool = false
        )
        /// No usable text in the reply.
        case emptyReply
        /// The model stopped at the length limit: the reply is cut in half.
        case truncated
        case responseFailed(message: String)
        /// Takku Credit answered 402: the balance is used up.
        case noCredit

        public var errorDescription: String? {
            switch self {
            // Looked up in the app's string catalog (Bundle.main), so the app can translate them.
            case .http(let status, let message, let reasoning, let hasExtraParameters):
                Self.withProfileSettings(
                    String(localized: "The provider answered with error \(status): \(message)"), reasoning, hasExtraParameters
                )
            case .emptyReply:
                String(localized: "The provider returned no text.")
            case .truncated:
                String(localized: "The model's reply was cut off by the length limit.")
            case .responseFailed(let message):
                String(localized: "The provider could not complete the response: \(message)")
            case .noCredit:
                String(localized: "Your Takku Credit is used up. Add credit in Settings → Summary Profiles, then Retry the Meeting.")
            }
        }

        /// The error with what the Profile sets beyond a plain request, never the Profile's name
        /// or the parameters themselves: the message also goes to the log, which *Report a
        /// problem…* includes.
        private static func withProfileSettings(
            _ error: String, _ reasoning: ProviderProfile.ReasoningEffort?, _ hasExtraParameters: Bool
        ) -> String {
            let settings: String? = switch (reasoning, hasExtraParameters) {
            case (let reasoning?, true):
                String(localized: "The Profile sets Reasoning: \(reasoning.displayName) and Extra parameters.")
            case (let reasoning?, false):
                String(localized: "The Profile sets Reasoning: \(reasoning.displayName).")
            case (nil, true):
                String(localized: "The Profile sets Extra parameters.")
            case (nil, false):
                nil
            }
            guard let settings else { return error }
            // A message cut at 300 characters ends with "…": no full stop after it.
            return error + (error.last.map { ".!?…".contains($0) } == true ? " " : ". ") + settings
        }
    }

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let baseURL: URL
    private let apiKey: String?
    private let model: String
    private let api: ProviderProfile.API
    private let reasoning: ProviderProfile.ReasoningEffort?
    private let extraParameters: String?
    private var transport: Transport

    public init(
        baseURL: URL, apiKey: String?, model: String, reasoning: ProviderProfile.ReasoningEffort? = nil,
        extraParameters: String? = nil, api: ProviderProfile.API = .chatCompletions, transport: @escaping Transport
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.api = api
        self.reasoning = reasoning
        self.extraParameters = extraParameters
        self.transport = transport
    }

    /// The same client, with every request and its reply also copied to the Summary log as `kind`.
    public func recording(into log: SummaryLog.Recorder, as kind: SummaryLog.Call.Kind) -> ChatClient {
        var client = self
        let transport = self.transport
        client.transport = { request in
            let started = ContinuousClock.now
            let seconds = { (ContinuousClock.now - started) / .seconds(1) }
            do {
                let (data, response) = try await transport(request)
                await log.append(SummaryLog.Call(
                    kind: kind, request: request.httpBody ?? Data(), response: data, status: response.statusCode,
                    seconds: seconds(), error: nil
                ))
                return (data, response)
            } catch {
                await log.append(SummaryLog.Call(
                    kind: kind, request: request.httpBody ?? Data(), response: nil, status: nil,
                    seconds: seconds(), error: error.localizedDescription
                ))
                throw error
            }
        }
        return client
    }

    public func complete(_ messages: [ChatMessage]) async throws -> String {
        let extra = try ExtraParameters.parse(extraParameters ?? "")
        var request = URLRequest(url: baseURL.appending(path: api == .responses ? "responses" : "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: Data
        let reasoningKey: String
        if api == .responses {
            body = try JSONEncoder().encode(ResponsesRequest(model: model, input: messages, reasoning: reasoning.map(RequestBody.Reasoning.init)))
            reasoningKey = "reasoning"
        } else {
            let chatBody = RequestBody(model: model, messages: messages, reasoning: reasoning, openRouter: Self.isOpenRouter(baseURL))
            body = try JSONEncoder().encode(chatBody)
            reasoningKey = chatBody.reasoningKey.stringValue
        }
        request.httpBody = try ExtraParameters.applying(extra, to: body)

        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 402, baseURL.host()?.lowercased() == TakkuCredit.host { throw Failure.noCredit }
            let refused = [400, 422].contains(response.statusCode)
            // The menu's level is not named when the Extra parameters replaced it: it was not sent.
            let sentReasoning = extra[reasoningKey] == nil ? reasoning : nil
            throw Failure.http(
                status: response.statusCode, message: Self.errorMessage(in: data),
                reasoning: refused ? sentReasoning : nil, hasExtraParameters: refused && !extra.isEmpty
            )
        }
        let content: String?
        if api == .responses {
            let result = try? JSONDecoder().decode(ResponsesResponse.self, from: data)
            if result?.error != nil { throw Failure.responseFailed(message: Self.errorMessage(in: data)) }
            if result?.status == "incomplete", result?.incompleteDetails?.reason == "max_output_tokens" {
                throw Failure.truncated
            }
            guard result?.status == "completed" else { throw Failure.emptyReply }
            content = result?.output?
                .filter { $0.type == "message" && $0.role == "assistant" }
                .flatMap { $0.content ?? [] }
                .filter { $0.type == "output_text" }
                .compactMap(\.text).joined()
        } else {
            let choice = (try? JSONDecoder().decode(ResponseBody.self, from: data))?.choices.first
            guard choice?.finishReason != "length" else { throw Failure.truncated }
            content = choice?.message.content
        }
        guard let content,
              case let reply = Self.removingThinking(content).trimmingCharacters(in: .whitespacesAndNewlines),
              !reply.isEmpty
        else {
            throw Failure.emptyReply
        }
        return reply
    }

    /// OpenRouter takes the reasoning in its own format; every other provider as OpenAI does.
    private static func isOpenRouter(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "openrouter.ai" || host.hasSuffix(".openrouter.ai")
    }

    /// Some models write their reasoning in the reply, between `<think>` tags (`<thinking>` for
    /// others), and the opening tag is sometimes missing: only what follows the last closing tag
    /// is the answer.
    private static func removingThinking(_ reply: String) -> String {
        let ends = ["</think>", "</thinking>"].compactMap { reply.range(of: $0, options: .backwards)?.upperBound }
        return ends.max().map { String(reply[$0...]) } ?? reply
    }

    /// The error message in the OpenAI format (`{"error":{"message":…}}`), otherwise the raw text,
    /// cut at 300 characters: some providers put whole JSON bodies in it, and what the Profile
    /// sets, added after it, must stay readable in a notification or in the note.
    static func errorMessage(in data: Data) -> String {
        struct ErrorBody: Decodable {
            struct Detail: Decodable { let message: String }
            let error: Detail
        }
        let message = ((try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message ?? String(decoding: data, as: UTF8.self))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.count > 300 ? message.prefix(300).trimmingCharacters(in: .whitespacesAndNewlines) + "…" : message
    }

    private struct ResponsesRequest: Encodable {
        let model: String
        let input: [ChatMessage]
        let reasoning: RequestBody.Reasoning?
        let store = false
    }

    private struct ResponsesResponse: Decodable {
        struct Output: Decodable {
            struct Content: Decodable {
                let type: String
                let text: String?
            }
            let type: String
            let role: String?
            let content: [Content]?
        }
        struct IncompleteDetails: Decodable {
            let reason: String?
        }
        struct ErrorDetail: Decodable {
            let message: String
        }
        let status: String
        let output: [Output]?
        let incompleteDetails: IncompleteDetails?
        let error: ErrorDetail?

        enum CodingKeys: String, CodingKey {
            case status, output, error
            case incompleteDetails = "incomplete_details"
        }
    }

    private struct RequestBody: Encodable {
        struct Reasoning: Encodable {
            let effort: ProviderProfile.ReasoningEffort
        }
        let model: String
        let messages: [ChatMessage]
        /// OpenRouter: `"reasoning": {"effort": "high"}`.
        let reasoning: Reasoning?
        /// Everyone else, as OpenAI: `"reasoning_effort": "high"`. Both are left out when `nil`.
        let reasoningEffort: ProviderProfile.ReasoningEffort?

        init(model: String, messages: [ChatMessage], reasoning: ProviderProfile.ReasoningEffort?, openRouter: Bool) {
            self.model = model
            self.messages = messages
            self.reasoning = openRouter ? reasoning.map(Reasoning.init) : nil
            reasoningEffort = openRouter ? nil : reasoning
            reasoningKey = openRouter ? .reasoning : .reasoningEffort
        }

        /// The key the reasoning level goes under for this provider.
        let reasoningKey: CodingKeys

        enum CodingKeys: String, CodingKey {
            case model, messages, reasoning
            case reasoningEffort = "reasoning_effort"
        }
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?

                /// Mistral, when the model reasons, sends a list of chunks instead of the text:
                /// the answer is in the `text` chunks, the reasoning in the `thinking` ones.
                struct Chunk: Decodable {
                    let type: String
                    let text: String?
                }

                enum CodingKeys: String, CodingKey { case content }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    if let text = try? container.decodeIfPresent(String.self, forKey: .content) {
                        content = text
                    } else if let chunks = try? container.decodeIfPresent([Chunk].self, forKey: .content) {
                        content = chunks.filter { $0.type == "text" }.compactMap(\.text).joined()
                    } else {
                        content = nil
                    }
                }
            }
            let message: Message
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        let choices: [Choice]
    }
}
