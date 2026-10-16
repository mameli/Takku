import Foundation
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "summary")

extension ChatClient {
    /// A slow local model can go minutes without sending a byte before answering:
    /// the default timeout (60 s of silence) is not enough.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 900
        configuration.timeoutIntervalForResource = 1_800
        return URLSession(configuration: configuration)
    }()

    /// The request in flight, for the progress logs: a client sends its requests one at a time.
    private struct Timing {
        var started = ContinuousClock.now
        var lastLog = ContinuousClock.now
        var sawToken = false
    }

    init(profile: ProviderProfile) throws {
        let url = try profile.validatedBaseURL()
        let model = profile.model
        let timing = OSAllocatedUnfairLock(initialState: Timing())
        self.init(baseURL: url, apiKey: Keychain.apiKey(for: profile.id), model: model, transport: { request in
            // Every request with its timing: compare it with the provider's own logs.
            let host = request.url?.host() ?? "?"
            let sent = request.httpBody?.count ?? 0
            let started = ContinuousClock.now
            timing.withLock { $0 = Timing(started: started, lastLog: started) }
            logger.notice("LLM request to \(host, privacy: .public), model \(model, privacy: .public), \(sent) bytes")
            do {
                let (bytes, response) = try await Self.session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                logger.notice("LLM reply HTTP \(http.statusCode) after \(secondsSince(started), privacy: .public)")
                let lines = AsyncThrowingStream<String, Error> { continuation in
                    let reading = Task {
                        do {
                            for try await line in bytes.lines { continuation.yield(line) }
                            continuation.finish()
                        } catch {
                            // Cancelled by the consumer leaving early (after [DONE]): not a failure.
                            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                            if !cancelled {
                                logger.error("LLM reply broken after \(secondsSince(started), privacy: .public): \(error, privacy: .public)")
                            }
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in reading.cancel() }
                }
                return (lines, http)
            } catch {
                logger.error("LLM request failed after \(secondsSince(started), privacy: .public): \(error, privacy: .public)")
                throw error
            }
        }, progress: { received in
            let now = ContinuousClock.now
            let (started, firstToken, periodic) = timing.withLock { state in
                let firstToken = !state.sawToken && received.reasoningCharacters + received.replyCharacters > 0
                state.sawToken = state.sawToken || firstToken
                let periodic = !received.isComplete && now - state.lastLog >= .seconds(15)
                if periodic { state.lastLog = now }
                return (state.started, firstToken, periodic)
            }
            if firstToken, !received.isComplete {
                logger.notice("LLM first token after \(secondsSince(started), privacy: .public)")
            }
            guard received.isComplete || periodic else { return }
            logger.notice("""
                LLM \(received.isComplete ? "reply done in" : "streaming", privacy: .public) \(secondsSince(started), privacy: .public): \
                \(received.reasoningCharacters) reasoning chars, \(received.replyCharacters) reply chars
                """)
        })
    }
}
