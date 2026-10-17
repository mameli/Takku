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

/// Client for any server with an OpenAI-compatible API (`POST {baseURL}/chat/completions`):
/// remote providers and local servers such as llama.cpp or Ollama (ADR 0004).
public struct ChatClient: Sendable {
    public enum Failure: LocalizedError, Equatable {
        /// The provider answered with an error: HTTP status and message as it sent them.
        case http(status: Int, message: String)
        /// No usable text in the reply.
        case emptyReply
        /// The model stopped at the length limit: the reply is cut in half.
        case truncated

        public var errorDescription: String? {
            switch self {
            // Looked up in the app's string catalog (Bundle.main), so the app can translate them.
            case .http(let status, let message):
                String(localized: "The provider answered with error \(status): \(message)")
            case .emptyReply:
                String(localized: "The provider returned no text.")
            case .truncated:
                String(localized: "The model's reply was cut off by the length limit.")
            }
        }
    }

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let baseURL: URL
    private let apiKey: String?
    private let model: String
    private let transport: Transport

    public init(baseURL: URL, apiKey: String?, model: String, transport: @escaping Transport) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
    }

    public func complete(_ messages: [ChatMessage]) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(RequestBody(model: model, messages: messages))

        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Failure.http(status: response.statusCode, message: Self.errorMessage(in: data))
        }
        let choice = (try? JSONDecoder().decode(ResponseBody.self, from: data))?.choices.first
        guard choice?.finishReason != "length" else { throw Failure.truncated }
        guard let reply = choice?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else {
            throw Failure.emptyReply
        }
        return reply
    }

    /// The error message in the OpenAI format (`{"error":{"message":…}}`), otherwise the raw text.
    private static func errorMessage(in data: Data) -> String {
        struct ErrorBody: Decodable {
            struct Detail: Decodable { let message: String }
            let error: Detail
        }
        if let body = try? JSONDecoder().decode(ErrorBody.self, from: data) {
            return body.error.message
        }
        return String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [ChatMessage]
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
}
