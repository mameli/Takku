import Foundation
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "summary")

extension ChatClient {
    /// A slow local model can go minutes without sending a byte before answering:
    /// the default timeout (60 s of silence) is not enough.
    private static let localSession = session(silence: 900, total: 1_800)
    /// A remote provider sends nothing until its reply is complete (no streaming): a long Transcript
    /// with a lot of reasoning took 217 s. A request it leaves hanging fails after 10 minutes of
    /// silence or 15 in all, instead of holding the queue for 30; *Stop processing* ends it sooner.
    private static let remoteSession = session(silence: 600, total: 900)

    private static func session(silence: TimeInterval, total: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = silence
        configuration.timeoutIntervalForResource = total
        return URLSession(configuration: configuration)
    }

    init(profile: ProviderProfile) throws {
        if profile.isAppleIntelligence {
            if let unavailability = AppleIntelligenceModel.unavailability { throw unavailability }
            self = AppleIntelligenceModel.client()!
            return
        }
        let url = try profile.validatedBaseURL()
        let model = profile.model
        // Never the address: the log goes in *Report a problem…*, and a Profile's address can name a company.
        let place = profile.runsOnThisMac ? "on this Mac" : "remote"
        let session = profile.runsOnThisMac ? Self.localSession : Self.remoteSession
        self.init(
            baseURL: url, apiKey: Keychain.apiKey(for: profile.id), model: model,
            reasoning: profile.reasoning, extraParameters: profile.extraParameters, api: profile.api
        ) { request in
            // Every request with its timing: compare it with the provider's own logs.
            let sent = request.httpBody?.count ?? 0
            let started = ContinuousClock.now
            logger.notice("LLM request \(place, privacy: .public), model \(model, privacy: .public), \(sent) bytes")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                logger.notice("LLM reply HTTP \(http.statusCode), \(data.count) bytes in \(secondsSince(started), privacy: .public)")
                return (data, http)
            } catch {
                logger.error("LLM request failed after \(secondsSince(started), privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
    }
}

extension TakkuCredit {
    /// The gateway's balance and packs: short requests, on the shared session.
    static let transport: ChatClient.Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
