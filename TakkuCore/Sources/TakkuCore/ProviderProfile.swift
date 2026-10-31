import Foundation

/// A named configuration of a Provider for the Summary. The API key is not stored here:
/// it lives in the Keychain, under the Profile's identifier.
public struct ProviderProfile: Codable, Identifiable, Equatable, Hashable, Sendable {
    public static let defaultMaxContextTokens = 32_000

    public var id: UUID
    public var name: String
    public var baseURL: String
    public var model: String
    public var api: API
    /// Tokens the model accepts in one request: beyond that the Transcript is split into blocks.
    public var maxContextTokens: Int
    /// How much the model reasons before answering; `nil` leaves it to the model.
    public var reasoning: ReasoningEffort?
    /// What the model needs beyond the reasoning level, as the user wrote it: a JSON object added
    /// to every request (see `ExtraParameters`). `nil` without any.
    public var extraParameters: String?

    public init(
        id: UUID = UUID(), name: String, baseURL: String, model: String, maxContextTokens: Int,
        reasoning: ReasoningEffort? = nil, extraParameters: String? = nil, api: API = .chatCompletions
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.api = api
        self.maxContextTokens = maxContextTokens
        self.reasoning = reasoning
        self.extraParameters = extraParameters
    }

    public enum API: String, Codable, CaseIterable, Hashable, Sendable {
        case chatCompletions = "chat_completions"
        case responses = "responses_api"
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, model, api, maxContextTokens, reasoning, extraParameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decode(String.self, forKey: .model)
        api = try container.decodeIfPresent(API.self, forKey: .api) ?? .chatCompletions
        maxContextTokens = try container.decode(Int.self, forKey: .maxContextTokens)
        reasoning = try container.decodeIfPresent(ReasoningEffort.self, forKey: .reasoning)
        extraParameters = try container.decodeIfPresent(String.self, forKey: .extraParameters)
    }

    /// The Profiles a new user finds in Settings, ready once the API key is in (Ollama needs none):
    /// Takku Credit first, which needs nothing but the key from its email, then a model on this Mac,
    /// then three remote providers. New identifiers at every call.
    public static func readyMade() -> [ProviderProfile] {
        [
            takkuCredit(),
            ProviderProfile(
                name: "Ollama", baseURL: "http://localhost:11434/v1", model: "hf.co/ggml-org/gemma-4-E4B-it-GGUF:Q4_0",
                maxContextTokens: defaultMaxContextTokens
            ),
            ProviderProfile(
                name: "Mistral", baseURL: "https://api.mistral.ai/v1", model: "zai-glm-5-3-flash", maxContextTokens: 128_000
            ),
            ProviderProfile(
                name: "TensorX", baseURL: "https://api.tensorx.ai/v1", model: "deepseek/deepseek-v4.1-flash-1017",
                maxContextTokens: 128_000, reasoning: .low
            ),
            ProviderProfile(
                name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "anthropic/claude-haiku-5.5",
                maxContextTokens: 128_000
            ),
        ]
    }

    /// Sent as `reasoning.effort` for Responses and OpenRouter, otherwise as `reasoning_effort`.
    /// Not every model accepts every level, and some cannot turn reasoning off.
    public enum ReasoningEffort: String, Codable, CaseIterable, Hashable, Sendable {
        case off = "none", low, medium, high

        /// The level as the Profile editor shows it. Looked up in the app's string catalog
        /// (Bundle.main), so the app can translate it.
        public var displayName: String {
            switch self {
            case .off: String(localized: "Off")
            case .low: String(localized: "Low")
            case .medium: String(localized: "Medium")
            case .high: String(localized: "High")
            }
        }
    }

    public enum URLError: LocalizedError, Equatable {
        case invalid(String)
        case insecure(String)

        public var errorDescription: String? {
            switch self {
            case .invalid(let url):
                String(localized: "Invalid Profile URL: \"\(url)\" (http:// or https:// and an address are needed).")
            case .insecure(let url):
                String(localized: "Plain-text Profile URL: \"\(url)\". Use https://; http:// is allowed only for servers on this Mac.")
            }
        }
    }

    /// Plain HTTP only towards this Mac: to any other machine, even on the local network,
    /// the key and the Transcript would travel readable.
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    /// The base URL to call, if it is usable.
    public func validatedBaseURL() throws -> URL {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty
        else { throw URLError.invalid(baseURL) }
        guard scheme == "https" || Self.loopbackHosts.contains(host.lowercased()) else {
            throw URLError.insecure(baseURL)
        }
        return url
    }

    /// Whether the provider is a server on this Mac (llama.cpp, Ollama, LM Studio).
    public var runsOnThisMac: Bool {
        guard let host = URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host() else { return false }
        return Self.loopbackHosts.contains(host.lowercased())
    }

    /// The name shown in menus, even when the user did not type one. "Untitled" is looked up
    /// in the app's string catalog (Bundle.main), so the app can translate it.
    public var displayName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "Untitled") : name
    }
}
