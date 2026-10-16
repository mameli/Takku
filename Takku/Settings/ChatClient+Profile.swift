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

    init(profile: ProviderProfile) throws {
        let url = try profile.validatedBaseURL()
        let model = profile.model
        self.init(baseURL: url, apiKey: Keychain.apiKey(for: profile.id), model: model) { request in
            // Every request with its timing: compare it with the provider's own logs.
            let host = request.url?.host() ?? "?"
            let sent = request.httpBody?.count ?? 0
            let started = ContinuousClock.now
            logger.notice("LLM request to \(host, privacy: .public), model \(model, privacy: .public), \(sent) bytes")
            do {
                let (data, response) = try await Self.session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                logger.notice("LLM reply HTTP \(http.statusCode), \(data.count) bytes in \(secondsSince(started), privacy: .public)")
                return (data, http)
            } catch {
                logger.error("LLM request failed after \(secondsSince(started), privacy: .public): \(error, privacy: .public)")
                throw error
            }
        }
    }
}
