import Foundation
import TakkuCore
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

private let logger = Logger(subsystem: "app.takku.takku", category: "summary")

/// Apple Intelligence's model on this Mac, through Foundation Models: whether it can be used, how
/// much context it has, and the `ChatClient` transport that hands it each request (see
/// `AppleIntelligence`). Every request is a new session: Takku's requests carry all they need.
enum AppleIntelligenceModel {
    enum Unavailable: LocalizedError {
        case oldSystem, deviceNotEligible, turnedOff, notReady, other
        case contextExceeded, refused

        var errorDescription: String? {
            switch self {
            case .oldSystem: String(localized: "Apple Intelligence needs macOS 26 or later.")
            case .deviceNotEligible: String(localized: "This Mac does not support Apple Intelligence.")
            case .turnedOff: String(localized: "Apple Intelligence is turned off: turn it on in System Settings → Apple Intelligence & Siri.")
            case .notReady: String(localized: "Apple Intelligence is still getting its model ready: try again in a few minutes.")
            case .other: String(localized: "Apple Intelligence is not available on this Mac right now.")
            case .contextExceeded: String(localized: "The request was too long for Apple Intelligence.")
            case .refused: String(localized: "Apple Intelligence refused to answer about this text.")
            }
        }
    }

    /// Why the model cannot be used now, `nil` when it can.
    static var unavailability: Unavailable? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return .oldSystem }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .turnedOff
        case .unavailable(.modelNotReady): return .notReady
        case .unavailable: return .other
        }
        #else
        return .oldSystem
        #endif
    }

    static var isAvailable: Bool { unavailability == nil }

    /// Tokens the model takes in one request, question and answer together.
    static var contextTokens: Int {
        #if canImport(FoundationModels) && compiler(>=6.4)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.contextSize }
        #endif
        return AppleIntelligence.defaultContextTokens
    }

    /// Answers a Chat Completions request with the model, as a server would.
    static let transport: ChatClient.Transport = { request in
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw Unavailable.oldSystem }
        if let unavailability { throw unavailability }
        let (instructions, prompt) = try AppleIntelligence.conversation(fromRequestBody: request.httpBody ?? Data())
        let started = ContinuousClock.now
        logger.notice("LLM request on this Mac, model \(AppleIntelligence.model, privacy: .public), \(prompt.count) characters")
        // Meetings talk about anything: the default guardrails refuse too much of it.
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let reply = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.3)).content
            logger.notice("LLM reply \(reply.count) characters in \(secondsSince(started), privacy: .public)")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (AppleIntelligence.responseBody(reply), response)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            logger.error("LLM request too long for the model after \(secondsSince(started), privacy: .public)")
            throw Unavailable.contextExceeded
        } catch LanguageModelSession.GenerationError.refusal, LanguageModelSession.GenerationError.guardrailViolation {
            logger.error("LLM request refused after \(secondsSince(started), privacy: .public)")
            throw Unavailable.refused
        }
        #else
        throw Unavailable.oldSystem
        #endif
    }

    /// A client for Apple Intelligence, `nil` when it cannot be used now.
    static func client() -> ChatClient? {
        guard isAvailable, let url = URL(string: AppleIntelligence.baseURL) else { return nil }
        return ChatClient(baseURL: url, apiKey: nil, model: AppleIntelligence.model, transport: transport)
    }
}
