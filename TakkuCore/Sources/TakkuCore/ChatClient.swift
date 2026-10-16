import Foundation
import Synchronization

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

/// Client for any server with an OpenAI-compatible API (`POST {baseURL}/chat/completions`):
/// remote providers and local servers such as llama.cpp or Ollama (ADR 0004).
/// Replies are streamed (`stream: true`), so a slow model shows progress instead of silence.
public struct ChatClient: Sendable {
    public enum Failure: LocalizedError, Equatable {
        /// The provider answered with an error: HTTP status and message as it sent them.
        case http(status: Int, message: String)
        /// No usable text in the reply.
        case emptyReply
        /// The model stopped at the length limit: the reply is cut in half.
        case truncated
        /// An error event in the middle of the stream, without an HTTP-style code.
        case reported(message: String)
        /// The stream ended without `[DONE]` or a `finish_reason`: the reply is cut short.
        case incomplete

        public var errorDescription: String? {
            switch self {
            // Looked up in the app's string catalog (Bundle.main), so the app can translate them.
            case .http(let status, let message):
                String(localized: "The provider answered with error \(status): \(message)")
            case .emptyReply:
                String(localized: "The provider returned no text.")
            case .truncated:
                String(localized: "The model's reply was cut off by the length limit.")
            case .reported(let message):
                String(localized: "The provider reported an error: \(message)")
            case .incomplete:
                String(localized: "The provider's reply stopped before the end.")
            }
        }
    }

    /// The reply's lines as they arrive, available once the headers are in.
    public typealias Transport = @Sendable (URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse)

    /// What has arrived of a reply. Reasoning is only counted, never kept.
    public struct StreamProgress: Sendable, Equatable {
        public var reasoningCharacters = 0
        public var replyCharacters = 0
        public var isComplete = false

        public init(reasoningCharacters: Int = 0, replyCharacters: Int = 0, isComplete: Bool = false) {
            self.reasoningCharacters = reasoningCharacters
            self.replyCharacters = replyCharacters
            self.isComplete = isComplete
        }
    }

    private let baseURL: URL
    private let apiKey: String?
    private let model: String
    private let transport: Transport
    private let progress: @Sendable (StreamProgress) -> Void
    /// Set once the provider refuses streaming: shared by copies of this client, so the
    /// following requests go without it straight away.
    private let streamingRefused = SharedFlag()

    /// `progress` is called at every streamed chunk and once more, complete, at the end.
    public init(
        baseURL: URL, apiKey: String?, model: String, transport: @escaping Transport,
        progress: @escaping @Sendable (StreamProgress) -> Void = { _ in }
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
        self.progress = progress
    }

    public func complete(_ messages: [ChatMessage]) async throws -> String {
        try await complete(messages, stream: !streamingRefused.value.withLock { $0 })
    }

    private func complete(_ messages: [ChatMessage], stream: Bool) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(RequestBody(model: model, messages: messages, stream: stream))

        let (lines, response) = try await transport(request)
        var body: [String] = []
        guard (200..<300).contains(response.statusCode) else {
            for try await line in lines { body.append(line) }
            let message = Self.errorMessage(in: Self.joined(body))
            // Some providers refuse streaming for an account or model; the same request without it works.
            if stream, response.statusCode == 400, message.localizedCaseInsensitiveContains("stream") {
                streamingRefused.value.withLock { $0 = true }
                return try await complete(messages, stream: false)
            }
            throw Failure.http(status: response.statusCode, message: message)
        }

        var reply = ""
        var finishReason: String?
        var sawDone = false
        var received = StreamProgress()
        // A server that ignores `stream` sends the whole JSON body instead of `data:` events.
        var streaming: Bool?
        let decoder = JSONDecoder()
        for try await line in lines {
            if streaming == nil {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                // Some providers open the stream with a `: PROCESSING` comment; a JSON body never starts so.
                streaming = ["data:", ":", "event:"].contains { line.hasPrefix($0) }
            }
            guard streaming == true else {
                body.append(line)
                continue
            }
            // Blank lines, `:` keep-alives and `event:` lines carry nothing.
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                sawDone = true
                break
            }
            guard let chunk = try? decoder.decode(Chunk.self, from: Data(payload.utf8)) else { continue }
            if let error = chunk.error {
                let message = error.message ?? error.code ?? payload
                if let status = error.status { throw Failure.http(status: status, message: message) }
                throw Failure.reported(message: message)
            }
            guard let choice = chunk.choices?.first else { continue }
            let content = choice.delta?.content ?? ""
            reply += content
            received.replyCharacters += content.count
            received.reasoningCharacters += (choice.delta?.reasoningContent ?? choice.delta?.reasoning)?.count ?? 0
            finishReason = choice.finishReason ?? finishReason
            progress(received)
        }
        if streaming != true {
            let choice = (try? decoder.decode(ResponseBody.self, from: Self.joined(body)))?.choices.first
            reply = choice?.message.content ?? ""
            finishReason = choice?.finishReason
            received.replyCharacters = reply.count
        } else if !sawDone, finishReason == nil {
            throw Failure.incomplete
        }
        received.isComplete = true
        progress(received)

        guard finishReason != "length" else { throw Failure.truncated }
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyReply }
        return trimmed
    }

    private static func joined(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    /// The error message in the OpenAI format (`{"error":{"message":…}}`), otherwise the raw text.
    private static func errorMessage(in data: Data) -> String {
        if let body = try? JSONDecoder().decode(ErrorBody.self, from: data) {
            return body.error.message
        }
        return String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
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

    /// One `data:` event of a streamed reply, or the error a provider sends mid-stream.
    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
                let reasoningContent: String?
                let reasoning: String?

                enum CodingKeys: String, CodingKey {
                    case content, reasoning
                    case reasoningContent = "reasoning_content"
                }
            }
            let delta: Delta?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }
        let choices: [Choice]?
        let error: StreamError?
    }

    /// The error of a mid-stream chunk: `{"error":{"message":…,"code":…}}`, or a bare string.
    /// `status` is set when the code is a number, as an HTTP status is.
    private struct StreamError: Decodable {
        let message: String?
        let code: String?
        let status: Int?

        enum CodingKeys: String, CodingKey {
            case message, code
        }

        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                message = text
                code = nil
                status = nil
                return
            }
            let object = try decoder.container(keyedBy: CodingKeys.self)
            message = try? object.decode(String.self, forKey: .message)
            code = try? object.decode(String.self, forKey: .code)
            status = try? object.decode(Int.self, forKey: .code)
        }
    }
}

private final class SharedFlag: Sendable {
    let value = Mutex(false)
}
