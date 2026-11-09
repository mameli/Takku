import Foundation
import Testing
import TakkuCore

/// Answers each request as told, by its number from 0, and records the pauses asked for instead of waiting.
private final class FlakyTransport: @unchecked Sendable {
    enum Answer {
        case reply(String)
        case status(Int, retryAfter: String? = nil)
        case error(URLError.Code)
    }

    private let lock = NSLock()
    private let answer: (Int) -> Answer
    private var sent = 0
    private var slept: [Duration] = []

    var requests: Int { lock.withLock { sent } }
    var waits: [Duration] { lock.withLock { slept } }

    init(_ answer: @escaping (Int) -> Answer) {
        self.answer = answer
    }

    /// `answers` in order, then a reply to every request after them.
    convenience init(_ answers: Answer...) {
        self.init { $0 < answers.count ? answers[$0] : .reply("All good.") }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = lock.withLock {
            sent += 1
            return sent - 1
        }
        let (status, body, headers): (Int, String, [String: String]?)
        switch answer(index) {
        case .reply(let text):
            let content = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
            (status, body, headers) = (200, #"{"choices":[{"message":{"role":"assistant","content":"# + content + "}}]}", nil)
        case .status(let code, let retryAfter):
            (status, body, headers) = (code, #"{"error":{"message":"busy"}}"#, retryAfter.map { ["Retry-After": $0] })
        case .error(let code):
            throw URLError(code)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    func sleep(_ wait: Duration) async throws {
        lock.withLock { slept.append(wait) }
    }
}

@Suite("Requests sent again after a failure that passes by itself")
struct ChatClientRetryTests {
    let messages = [ChatMessage(role: .user, content: "Summarise.")]

    private func client(_ transport: FlakyTransport, after waits: [Duration] = ChatClient.retryWaits) -> ChatClient {
        ChatClient(baseURL: URL(string: "https://x.example/v1")!, apiKey: nil, model: "m", transport: transport.send)
            .retrying(after: waits, sleep: transport.sleep)
    }

    @Test("a busy provider is asked again after each pause, and the reply is the one that comes at last", arguments: [408, 429, 500, 503, 529])
    func busyProvider(status: Int) async throws {
        let transport = FlakyTransport(.status(status), .status(status))

        #expect(try await client(transport).complete(messages) == "All good.")
        #expect(transport.requests == 3)
        #expect(transport.waits == [.seconds(5), .seconds(20)])
    }

    @Test("a connection missing or lost is tried again", arguments: [
        URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
    ])
    func connectionLost(code: URLError.Code) async throws {
        let transport = FlakyTransport(.error(code))

        #expect(try await client(transport).complete(messages) == "All good.")
        #expect(transport.requests == 2)
        #expect(transport.waits == [.seconds(5)])
    }

    @Test("once the pauses are used up the failure is the last one, as the provider sent it")
    func givesUp() async {
        let busy = FlakyTransport { _ in .status(503) }
        await #expect(throws: ChatClient.Failure.http(status: 503, message: "busy")) {
            try await client(busy).complete(messages)
        }
        #expect(busy.requests == 3)

        let offline = FlakyTransport { _ in .error(.notConnectedToInternet) }
        await #expect(throws: URLError.self) { try await client(offline).complete(messages) }
        #expect(offline.requests == 3)
        #expect(offline.waits == [.seconds(5), .seconds(20)])
    }

    @Test("what the request itself causes is not sent again", arguments: [400, 401, 402, 404, 422])
    func refused(status: Int) async {
        let transport = FlakyTransport { _ in .status(status) }

        await #expect(throws: ChatClient.Failure.http(status: status, message: "busy")) {
            try await client(transport).complete(messages)
        }
        #expect(transport.requests == 1)
        #expect(transport.waits.isEmpty)
    }

    @Test("a timeout already took minutes: it is not tried again, and neither is a cancelled request")
    func timeout() async {
        for code in [URLError.Code.timedOut, .cancelled] {
            let transport = FlakyTransport { _ in .error(code) }

            await #expect(throws: URLError.self) { try await client(transport).complete(messages) }
            #expect(transport.requests == 1)
        }
    }

    @Test("the seconds the provider asks for are waited when they are more than the pause, not when over a minute")
    func retryAfter() async throws {
        let longer = FlakyTransport(.status(429, retryAfter: "30"), .status(429, retryAfter: " 2 "), .reply("Done."))
        #expect(try await client(longer, after: [.seconds(5), .seconds(5)]).complete(messages) == "Done.")
        #expect(longer.waits == [.seconds(30), .seconds(5)])

        let tooLong = FlakyTransport(.status(429, retryAfter: "120"))
        await #expect(throws: ChatClient.Failure.http(status: 429, message: "busy")) {
            try await client(tooLong).complete(messages)
        }
        #expect(tooLong.requests == 1)
        #expect(tooLong.waits.isEmpty)

        // A date, the header's other form, or nonsense: the pause is waited.
        let unread = FlakyTransport(.status(503, retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT"), .status(503, retryAfter: "nan"))
        #expect(try await client(unread).complete(messages) == "All good.")
        #expect(unread.waits == [.seconds(5), .seconds(20)])
    }

    @Test("Stop processing during a pause ends it: the request is not sent again")
    func stoppedWhileWaiting() async {
        let transport = FlakyTransport { _ in .status(503) }
        let client = ChatClient(baseURL: URL(string: "https://x.example/v1")!, apiKey: nil, model: "m", transport: transport.send)
            .retrying(sleep: { _ in throw CancellationError() })

        await #expect(throws: CancellationError.self) { try await client.complete(messages) }
        #expect(transport.requests == 1)
    }

    @Test("without the retry a client sends each request once, as Test connection does")
    func plainClientSendsOnce() async {
        let transport = FlakyTransport { _ in .status(503) }
        let client = ChatClient(baseURL: URL(string: "https://x.example/v1")!, apiKey: nil, model: "m", transport: transport.send)

        await #expect(throws: ChatClient.Failure.http(status: 503, message: "busy")) { try await client.complete(messages) }
        #expect(transport.requests == 1)
    }

    @Test("in blocks, a block that fails once is asked again: the partial summaries already written are kept, and the Summary log has every attempt")
    func blockAskedAgain() async throws {
        // Request 1 is the second block: the first one is written by then.
        let transport = FlakyTransport { $0 == 1 ? .status(503) : .reply("summary \($0)") }
        let client = ChatClient(baseURL: URL(string: "https://x.example/v1")!, apiKey: nil, model: "m", transport: transport.send)
        let transcript = Transcript(utterances: (0..<40).map { index in
            Utterance(
                track: index.isMultiple(of: 2) ? .others : .me, start: Double(index * 20), end: Double(index * 20 + 15),
                text: "Paragraph \(index): " + String(repeating: "words from the meeting ", count: 13)
            )
        })
        let prompt = SummaryPrompt(
            template: Template(fileName: "Notes", content: "### Topics"), personalNotes: "", transcript: transcript, meetingLanguage: "it"
        )
        let log = SummaryLog.Recorder()

        let summary = try await Summarizer(client: client, maxContextTokens: 8_192, log: log, retryWaits: [.zero]).summarize(prompt).text

        let calls = await log.calls
        #expect(calls.count == transport.requests)
        #expect(calls.map(\.status).filter { $0 != 200 } == [503])
        #expect(calls[1].kind == .partial)
        #expect(calls[1].status == 503)
        #expect(calls[2].request == calls[1].request)
        // The first block, the second one twice, the merge: at least.
        #expect(calls.count >= 4)
        #expect(calls.map(\.kind).last == .merge)
        #expect(summary == "summary \(calls.count - 1)")
    }
}
