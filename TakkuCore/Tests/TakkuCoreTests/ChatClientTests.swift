import Foundation
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

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = respond(requests.count)
        requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
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

    @Test("Responses API sends input and nested reasoning and reads only output text")
    func responsesRequest() async throws {
        let stub = StubTransport(body: #"""
            {"status":"completed","output":[
              {"type":"reasoning","summary":[]},
              {"type":"message","role":"assistant","content":[
                {"type":"output_text","text":"  ### Topics\n"},
                {"type":"output_text","text":"All good.\n"}
              ]}
            ]}
            """#)
        let client = ChatClient(
            baseURL: URL(string: "https://api.openai.com/v1/")!, apiKey: "sk-test", model: "m",
            reasoning: .high, extraParameters: #"{"max_output_tokens":4000}"#, api: .responses, transport: stub.send
        )

        #expect(try await client.complete(messages) == "### Topics\nAll good.")
        let request = try #require(stub.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "m")
        #expect(body["input"] as? [[String: String]] == messages.map { ["role": $0.role.rawValue, "content": $0.content] })
        #expect(body["messages"] == nil)
        #expect(body["store"] as? Bool == false)
        #expect(body["reasoning"] as? [String: String] == ["effort": "high"])
        #expect(body["reasoning_effort"] == nil)
        #expect(body["max_output_tokens"] as? Int == 4000)
    }

    @Test("Responses API leaves the output budget to the provider")
    func responsesNoOutputBudget() async throws {
        let stub = StubTransport(body: #"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"OK"}]}]}"#)
        let client = ChatClient(
            baseURL: URL(string: "https://api.example/v1")!, apiKey: nil, model: "m", api: .responses, transport: stub.send
        )

        #expect(try await client.complete(messages) == "OK")
        let body = try #require(JSONSerialization.jsonObject(with: stub.requests.first?.httpBody ?? Data()) as? [String: Any])
        #expect(body["max_output_tokens"] == nil)
    }

    @Test("Responses API rejects incomplete, failed and empty replies", arguments: [
        (#"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#, ChatClient.Failure.truncated),
        (#"{"status":"failed","error":{"message":"Model failed"}}"#, .responseFailed(message: "Model failed")),
        (#"{"status":"completed","output":[]}"#, .emptyReply),
        (#"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"No"}]}]}"#, .emptyReply),
        (#"{"status":"incomplete","incomplete_details":{"reason":"content_filter"},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Partial"}]}]}"#, .responseFailed(message: "content_filter")),
    ])
    func responsesFailure(body: String, failure: ChatClient.Failure) async {
        let stub = StubTransport(body: body)
        let client = ChatClient(
            baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: nil, model: "m", api: .responses, transport: stub.send
        )
        await #expect(throws: failure) { try await client.complete(messages) }
    }

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
    }

    @Test("OpenRouter gets the reasoning as an object, every other provider as reasoning_effort", arguments: [
        ("https://openrouter.ai/api/v1", ProviderProfile.ReasoningEffort.high, #"{"effort":"high"}"# as String?, nil as String?),
        ("https://openrouter.ai/api/v1", .off, #"{"effort":"none"}"#, nil),
        ("https://api.eurouter.ai/api/v1", .low, nil, "low"),
        ("https://api.mistral.ai/v1", .off, nil, "none"),
        ("http://localhost:8080/v1", .medium, nil, "medium"),
    ])
    func reasoning(baseURL: String, effort: ProviderProfile.ReasoningEffort, object: String?, field: String?) async throws {
        let stub = StubTransport(body: #"{"choices":[{"message":{"role":"assistant","content":"Ok."}}]}"#)
        let client = ChatClient(baseURL: URL(string: baseURL)!, apiKey: nil, model: "m", reasoning: effort, transport: stub.send)

        _ = try await client.complete(messages)

        let body = try #require(JSONSerialization.jsonObject(with: stub.requests.first?.httpBody ?? Data()) as? [String: Any])
        let sentObject = try body["reasoning"].map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        #expect(sentObject == object)
        #expect(body["reasoning_effort"] as? String == field)
    }

    @Test("without a reasoning level the request carries neither field", arguments: ["https://openrouter.ai/api/v1", "https://api.mistral.ai/v1"])
    func noReasoning(baseURL: String) async throws {
        let stub = StubTransport(body: #"{"choices":[{"message":{"role":"assistant","content":"Ok."}}]}"#)
        let client = ChatClient(baseURL: URL(string: baseURL)!, apiKey: nil, model: "m", transport: stub.send)

        _ = try await client.complete(messages)

        let body = try #require(JSONSerialization.jsonObject(with: stub.requests.first?.httpBody ?? Data()) as? [String: Any])
        #expect(body["reasoning"] == nil)
        #expect(body["reasoning_effort"] == nil)
    }

    @Test("Extra parameters go in the request as written, each key in place of Takku's", arguments: [
        // TensorX's DeepSeek: its own key, next to the menu's level.
        ("https://api.tensorx.ai/v1", ProviderProfile.ReasoningEffort.high, #"{"chat_template_kwargs":{"thinking":true}}"#,
         #"{"chat_template_kwargs":{"thinking":true},"reasoning_effort":"high"}"#),
        // A level the menu does not have replaces the menu's.
        ("https://api.tensorx.ai/v1", .medium, #"{"reasoning_effort":"xhigh"}"#, #"{"reasoning_effort":"xhigh"}"#),
        // No deep merge: OpenRouter's reasoning object is replaced whole, its effort is not kept.
        ("https://openrouter.ai/api/v1", .low, #"{"reasoning":{"max_tokens":4000}}"#, #"{"reasoning":{"max_tokens":4000}}"#),
        ("http://localhost:8080/v1", nil, "  ", "{}"),
    ] as [(String, ProviderProfile.ReasoningEffort?, String, String)])
    func extraParameters(baseURL: String, effort: ProviderProfile.ReasoningEffort?, extra: String, expected: String) async throws {
        let stub = StubTransport(body: #"{"choices":[{"message":{"role":"assistant","content":"Ok."}}]}"#)
        let client = ChatClient(
            baseURL: URL(string: baseURL)!, apiKey: nil, model: "m", reasoning: effort, extraParameters: extra, transport: stub.send
        )

        _ = try await client.complete(messages)

        var body = try #require(JSONSerialization.jsonObject(with: stub.requests.first?.httpBody ?? Data()) as? [String: Any])
        #expect(body.removeValue(forKey: "model") as? String == "m")
        #expect(body.removeValue(forKey: "messages") != nil)
        let rest = try #require(JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary)
        #expect(NSDictionary(dictionary: body) == rest)
    }

    @Test("invalid Extra parameters stop the request before it is sent")
    func invalidExtraParameters() async {
        let stub = StubTransport(body: #"{"choices":[{"message":{"role":"assistant","content":"Ok."}}]}"#)
        let client = ChatClient(
            baseURL: URL(string: "https://x.example/v1")!, apiKey: nil, model: "m", extraParameters: #"{"model":"other"}"#,
            transport: stub.send
        )

        await #expect(throws: ExtraParameters.Problem.reserved("model")) {
            try await client.complete(messages)
        }
        #expect(stub.requests.isEmpty)
    }

    @Test("a refused request says what the Profile adds to it, not the Profile's name or the parameters", arguments: [
        (400, ProviderProfile.ReasoningEffort.high, #"{"x":1}"#,
         "The provider answered with error 400: use xhigh. The Profile sets Reasoning: High and Extra parameters."),
        (422, .off, "", "The provider answered with error 422: use xhigh. The Profile sets Reasoning: Off."),
        (400, nil, #"{"x":1}"#, "The provider answered with error 400: use xhigh. The Profile sets Extra parameters."),
        (400, nil, "", "The provider answered with error 400: use xhigh"),
        // Not a refusal of what was sent: nothing added.
        (401, .high, #"{"x":1}"#, "The provider answered with error 401: use xhigh"),
        // The Extra parameters replaced the menu's level: it was not sent, so it is not named.
        (400, .high, #"{"reasoning_effort":"banana"}"#, "The provider answered with error 400: use xhigh. The Profile sets Extra parameters."),
    ] as [(Int, ProviderProfile.ReasoningEffort?, String, String)])
    func refusedWithProfileSettings(status: Int, effort: ProviderProfile.ReasoningEffort?, extra: String, expected: String) async {
        let stub = StubTransport(status: status, body: #"{"error":{"message":"use xhigh"}}"#)
        let client = ChatClient(
            baseURL: URL(string: "https://x.example/v1")!, apiKey: nil, model: "m", reasoning: effort, extraParameters: extra,
            transport: stub.send
        )

        do {
            _ = try await client.complete(messages)
            Issue.record("no error")
        } catch {
            #expect(error.localizedDescription == expected)
        }
    }

    @Test("a reply in chunks (Mistral reasoning) gives the text chunks, not the thinking")
    func chunks() async throws {
        let stub = StubTransport(body: #"""
            {"choices":[{"message":{"role":"assistant","content":[
              {"type":"thinking","thinking":[{"type":"text","text":"The user wants a summary."}]},
              {"type":"text","text":"### Topics\n"},{"type":"text","text":"All good."}
            ]}}]}
            """#)
        let client = ChatClient(baseURL: URL(string: "https://api.mistral.ai/v1")!, apiKey: nil, model: "m", transport: stub.send)

        #expect(try await client.complete(messages) == "### Topics\nAll good.")
    }

    @Test("reasoning written in the reply between think tags is not part of it", arguments: [
        "<think>\nThe user wants a summary.\n</think>\n\n### Topics\nAll good.",
        "The user wants a summary.\n</think>\n### Topics\nAll good.",
        "<thinking>Plan the sections.</thinking>### Topics\nAll good.",
        // The later closing tag wins, whichever it is.
        "<think>First.</think> More reasoning.</thinking>### Topics\nAll good.",
    ])
    func thinkTags(content: String) async throws {
        let reply = String(data: try JSONEncoder().encode(content), encoding: .utf8)!
        let stub = StubTransport(body: #"{"choices":[{"message":{"role":"assistant","content":"# + reply + "}}]}")
        let client = ChatClient(baseURL: URL(string: "https://api.scaleway.ai/v1")!, apiKey: nil, model: "m", transport: stub.send)

        #expect(try await client.complete(messages) == "### Topics\nAll good.")
    }

    @Test("a reply that is only reasoning is an empty reply")
    func onlyThinking() async {
        let stub = StubTransport(body: #"{"choices":[{"message":{"role":"assistant","content":"<think>Hmm.</think>\n"}}]}"#)
        let client = ChatClient(baseURL: URL(string: "https://x.example/v1")!, apiKey: nil, model: "m", transport: stub.send)

        await #expect(throws: ChatClient.Failure.emptyReply) {
            try await client.complete(messages)
        }
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
        let client = ChatClient(baseURL: URL(string: "https://x.example/v1")!, apiKey: nil, model: "m", transport: stub.send)

        await #expect(throws: ChatClient.Failure.http(status: 502, message: "Bad Gateway")) {
            try await client.complete(messages)
        }
    }

    @Test("a long error message is cut at 300 characters, so what the Profile sets stays readable", arguments: [
        // Regolo puts the whole upstream JSON in the message.
        #"{"error":{"message":"regolo.BadRequestError: "# + String(repeating: "x", count: 400) + #""}}"#,
        "<html>" + String(repeating: "x", count: 400) + "</html>",
    ])
    func longErrorMessage(body: String) async {
        let stub = StubTransport(status: 400, body: body)
        let client = ChatClient(
            baseURL: URL(string: "https://x.example/v1")!, apiKey: nil, model: "m", reasoning: .high, transport: stub.send
        )

        do {
            _ = try await client.complete(messages)
            Issue.record("no error")
        } catch let ChatClient.Failure.http(_, message, _, _) {
            #expect(message.count == 301)
            #expect(message.hasSuffix("…"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("after a message cut short, what the Profile sets follows the ellipsis without a full stop")
    func cutMessageWithProfileSettings() {
        let failure = ChatClient.Failure.http(status: 400, message: "Input should be 'none'…", reasoning: .high)
        #expect(failure.localizedDescription == "The provider answered with error 400: Input should be 'none'… The Profile sets Reasoning: High.")
    }

    @Test("on OpenRouter, a reasoning object in the Extra parameters replaces the menu's level, which is not named")
    func openRouterReasoningReplaced() async {
        let stub = StubTransport(status: 400, body: #"{"error":{"message":"bad reasoning"}}"#)
        let client = ChatClient(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!, apiKey: nil, model: "m", reasoning: .high,
            extraParameters: #"{"reasoning":{"max_tokens":-1}}"#, transport: stub.send
        )

        await #expect(throws: ChatClient.Failure.http(status: 400, message: "bad reasoning", hasExtraParameters: true)) {
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
        let client = ChatClient(baseURL: URL(string: "https://x.example/v1")!, apiKey: nil, model: "m", transport: stub.send)

        await #expect(throws: ChatClient.Failure.emptyReply) {
            try await client.complete(messages)
        }
    }

    @Test("a reply cut off by the length limit is an error, not half a Summary")
    func truncated() async {
        let stub = StubTransport(body: ####"{"choices":[{"message":{"role":"assistant","content":"### Topics\nThe budget"},"finish_reason":"length"}]}"####)
        let client = ChatClient(baseURL: URL(string: "https://x.example/v1")!, apiKey: nil, model: "m", transport: stub.send)

        await #expect(throws: ChatClient.Failure.truncated) {
            try await client.complete(messages)
        }
    }
}
