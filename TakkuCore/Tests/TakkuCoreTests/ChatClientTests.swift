import Foundation
import Synchronization
import Testing
import TakkuCore

/// Records requests and returns prepared replies: no network calls.
final class StubTransport: @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    private let respond: (Int) -> (status: Int, body: String)

    init(status: Int = 200, body: String) {
        respond = { _ in (status, body) }
    }

    /// `reply(n)` is the text of the reply to request number `n` (from 0).
    init(reply: @escaping (Int) -> String) {
        respond = { index in
            let content = String(data: try! JSONEncoder().encode(reply(index)), encoding: .utf8)!
            return (200, #"{"choices":[{"message":{"role":"assistant","content":"# + content + "}}]}")
        }
    }

    func send(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let (status, body) = respond(requests.count)
        requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        let lines = AsyncThrowingStream<String, Error> { continuation in
            body.split(separator: "\n", omittingEmptySubsequences: false).forEach { continuation.yield(String($0)) }
            continuation.finish()
        }
        return (lines, response)
    }

    /// The text of the `role` message of request number `index`.
    func message(_ index: Int, _ role: String) -> String? {
        guard let body = requests[index].httpBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: String]]
        else { return nil }
        return messages.first { $0["role"] == role }?["content"]
    }
}

@Suite("OpenAI-compatible client")
struct ChatClientTests {
    let messages = [ChatMessage(role: .system, content: "You are Takku."), ChatMessage(role: .user, content: "Summarise.")]

    @Test("the request goes to chat/completions with model, messages and key")
    func request() async throws {
        let stub = StubTransport(body: #"{"choices":[{"message":{"role":"assistant","content":"Ok."}}]}"#)
        let client = ChatClient(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!, apiKey: "sk-test", model: "openai/gpt-6-luna",
            transport: stub.send
        )

        _ = try await client.complete(messages)

        let request = try #require(stub.requests.first)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "openai/gpt-6-luna")
        let sent = try #require(body["messages"] as? [[String: String]])
        #expect(sent == [["role": "system", "content": "You are Takku."], ["role": "user", "content": "Summarise."]])
        #expect(body["stream"] as? Bool == true)
    }

    func makeClient(_ stub: StubTransport, progress: @escaping @Sendable (ChatClient.StreamProgress) -> Void = { _ in }) -> ChatClient {
        ChatClient(baseURL: URL(string: "https://x.example/v1")!, apiKey: nil, model: "m", transport: stub.send, progress: progress)
    }

    /// A streamed reply: one `data:` event per chunk, as OpenAI-compatible servers send it.
    func events(_ chunks: [String]) -> String {
        (chunks.map { "data: \($0)\n" } + ["data: [DONE]"]).joined(separator: "\n")
    }

    @Test("a streamed reply is assembled from its deltas, keep-alives ignored, and trimmed")
    func streamed() async throws {
        let body = ": keep-alive\n\n" + events([
            #"{"choices":[{"delta":{"role":"assistant","content":""}}]}"#,
            #"{"choices":[{"delta":{"content":"\n### Topics\n"}}]}"#,
            #"{"choices":[{"delta":{"content":"All good.\n"},"finish_reason":"stop"}]}"#,
        ]) + "\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"after DONE\"}}]}"
        let stub = StubTransport(body: body)
        let client = makeClient(stub)

        #expect(try await client.complete(messages) == "### Topics\nAll good.")
    }

    @Test("reasoning is left out of the reply but counted in the progress")
    func reasoning() async throws {
        let stub = StubTransport(body: events([
            #"{"choices":[{"delta":{"reasoning_content":"Let me think"}}]}"#,
            #"{"choices":[{"delta":{"reasoning":" more."}}]}"#,
            #"{"choices":[{"delta":{"content":"Ok."}}]}"#,
        ]))
        let seen = Mutex<[ChatClient.StreamProgress]>([])
        let client = makeClient(stub) { received in seen.withLock { $0.append(received) } }

        #expect(try await client.complete(messages) == "Ok.")
        #expect(seen.withLock { $0 } == [
            .init(reasoningCharacters: 12),
            .init(reasoningCharacters: 18),
            .init(reasoningCharacters: 18, replyCharacters: 3),
            .init(reasoningCharacters: 18, replyCharacters: 3, isComplete: true),
        ])
    }

    @Test("a reply without streaming reports one complete progress")
    func notStreamedProgress() async throws {
        let stub = StubTransport(body: #"{"choices":[{"message":{"role":"assistant","content":"Ok."}}]}"#)
        let seen = Mutex<[ChatClient.StreamProgress]>([])
        let client = makeClient(stub) { received in seen.withLock { $0.append(received) } }

        _ = try await client.complete(messages)
        #expect(seen.withLock { $0 } == [.init(replyCharacters: 3, isComplete: true)])
    }

    @Test("a streamed reply cut off by the length limit is an error")
    func streamedTruncated() async {
        let stub = StubTransport(body: events([
            ####"{"choices":[{"delta":{"content":"### Topics\nThe budget"}}]}"####,
            #"{"choices":[{"delta":{},"finish_reason":"length"}]}"#,
        ]))
        let client = makeClient(stub)

        await #expect(throws: ChatClient.Failure.truncated) {
            try await client.complete(messages)
        }
    }

    @Test("a streamed reply with only reasoning is an empty reply")
    func streamedEmpty() async {
        let stub = StubTransport(body: events([#"{"choices":[{"delta":{"reasoning_content":"Hmm."},"finish_reason":"stop"}]}"#]))
        let client = makeClient(stub)

        await #expect(throws: ChatClient.Failure.emptyReply) {
            try await client.complete(messages)
        }
    }

    @Test("an error event in the middle of the stream carries the provider's message")
    func streamedError() async {
        let stub = StubTransport(body: events([
            ####"{"choices":[{"delta":{"content":"### Topics"}}]}"####,
            #"{"error":{"message":"Upstream timed out","code":504}}"#,
        ]))
        let client = makeClient(stub)

        await #expect(throws: ChatClient.Failure.http(status: 504, message: "Upstream timed out")) {
            try await client.complete(messages)
        }
    }

    @Test("a mid-stream error without a status says so, whatever its shape", arguments: [
        (#"{"error":{"message":"overloaded"}}"#, "overloaded"),
        (#"{"error":"overloaded"}"#, "overloaded"),
        (#"{"error":{"code":"server_error"}}"#, "server_error"),
    ])
    func streamedErrorShapes(errorChunk: String, text: String) async {
        let stub = StubTransport(body: events([
            ####"{"choices":[{"delta":{"content":"### Topics"}}]}"####,
            errorChunk,
        ]))
        let client = makeClient(stub)

        do {
            _ = try await client.complete(messages)
            Issue.record("returned instead of throwing the provider error")
        } catch {
            #expect(error.localizedDescription == "The provider reported an error: \(text)")
        }
    }

    @Test("a stream that ends without [DONE] or finish_reason is an error, not a Summary")
    func streamedIncomplete() async {
        let stub = StubTransport(body: [
            ####"data: {"choices":[{"delta":{"content":"### Topics\nThe bud"}}]}"####,
            ####"data: {"choices":[{"delta":{"content":"get was appr"}}]}"####,
        ].joined(separator: "\n\n"))
        let client = makeClient(stub)

        await #expect(throws: ChatClient.Failure.incomplete) {
            try await client.complete(messages)
        }
    }

    @Test("a stream that ends with finish_reason but without [DONE] is a reply")
    func streamedWithoutDone() async throws {
        let stub = StubTransport(body: [
            ####"data: {"choices":[{"delta":{"content":"### Topics\nAll good."},"finish_reason":"stop"}]}"####,
        ].joined(separator: "\n\n"))
        let client = makeClient(stub)

        #expect(try await client.complete(messages) == "### Topics\nAll good.")
    }

    @Test("a 400 saying the organization must be verified to stream falls back to non-streamed requests")
    func streamingRefused() async throws {
        let refusal = #"{"error":{"message":"Your organization must be verified to stream this model.","type":"invalid_request_error","param":"stream","code":"unsupported_value"}}"#
        let streamFlags = Mutex<[Bool?]>([])
        let transport: ChatClient.Transport = { request in
            let json = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let stream = json?["stream"] as? Bool
            streamFlags.withLock { $0.append(stream) }
            let refused = stream == true
            let response = HTTPURLResponse(url: request.url!, statusCode: refused ? 400 : 200, httpVersion: nil, headerFields: nil)!
            let body = refused ? refusal : #"{"choices":[{"message":{"role":"assistant","content":"Non-streamed reply."},"finish_reason":"stop"}]}"#
            return (AsyncThrowingStream { $0.yield(body); $0.finish() }, response)
        }
        let client = ChatClient(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "sk-test", model: "o3", transport: transport)

        #expect(try await client.complete(messages) == "Non-streamed reply.")
        #expect(try await client.complete(messages) == "Non-streamed reply.")
        #expect(streamFlags.withLock { $0 } == [true, false, false])
    }

    @Test("without a key (local server) there is no Authorization header; the reply is trimmed")
    func localServer() async throws {
        let stub = StubTransport(body: #"{"choices":[{"message":{"role":"assistant","content":"\n  ### Topics\nAll good.\n\n"}}]}"#)
        let client = ChatClient(
            baseURL: URL(string: "http://localhost:8080/v1/")!, apiKey: nil, model: "locale", transport: stub.send
        )

        let reply = try await client.complete(messages)

        #expect(reply == "### Topics\nAll good.")
        #expect(stub.requests.first?.url?.absoluteString == "http://localhost:8080/v1/chat/completions")
        #expect(stub.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("an HTTP error carries the status and the provider's message")
    func httpError() async {
        let stub = StubTransport(status: 401, body: #"{"error":{"message":"No auth credentials found","code":401}}"#)
        let client = ChatClient(baseURL: URL(string: "https://x.example/v1")!, apiKey: "wrong", model: "m", transport: stub.send)

        await #expect(throws: ChatClient.Failure.http(status: 401, message: "No auth credentials found")) {
            try await client.complete(messages)
        }
    }

    @Test("an HTTP error without a JSON body carries the raw text")
    func httpErrorWithoutJSON() async {
        let stub = StubTransport(status: 502, body: "Bad Gateway")
        let client = makeClient(stub)

        await #expect(throws: ChatClient.Failure.http(status: 502, message: "Bad Gateway")) {
            try await client.complete(messages)
        }
    }

    @Test("a reply without text is an error, not an empty Summary", arguments: [
        #"{"choices":[{"message":{"role":"assistant","content":"   "}}]}"#,
        #"{"choices":[{"message":{"role":"assistant","content":null}}]}"#,
        #"{"choices":[]}"#,
        "not JSON",
    ])
    func emptyReply(body: String) async {
        let stub = StubTransport(body: body)
        let client = makeClient(stub)

        await #expect(throws: ChatClient.Failure.emptyReply) {
            try await client.complete(messages)
        }
    }

    @Test("a reply cut off by the length limit is an error, not half a Summary")
    func truncated() async {
        let stub = StubTransport(body: ####"{"choices":[{"message":{"role":"assistant","content":"### Topics\nThe budget"},"finish_reason":"length"}]}"####)
        let client = makeClient(stub)

        await #expect(throws: ChatClient.Failure.truncated) {
            try await client.complete(messages)
        }
    }
}
