import Foundation

/// Takku Credit: prepaid credit for the Summary, bought at takku.app and served by `api.takku.app`,
/// an OpenAI-compatible gateway with one model of its own. The Profile needs only the key that
/// arrives by email; the gateway also tells the balance and the link to add credit.
public enum TakkuCredit {
    public static let host = "api.takku.app"
    public static let baseURL = "https://api.takku.app/v1"
    /// The name the gateway expects: it ignores it and always uses its own model.
    public static let model = "takku-summary"
    public static let maxContextTokens = 128_000
    /// Where someone without a key buys a pack.
    public static let buyURL = URL(string: "https://takku.app/credit")!

    /// What `GET /v1/balance` answers. Money is in micro-euros (1 € = 1,000,000), as the gateway keeps it.
    public struct Balance: Decodable, Equatable, Sendable {
        public let micros: Int
        /// The Payment Link with this key's public id: whatever email is typed at checkout, the
        /// payment tops up this key. `nil` when the gateway has no link yet.
        public let topUpURL: URL?

        public init(micros: Int, topUpURL: URL?) {
            self.micros = micros
            self.topUpURL = topUpURL
        }

        public var euros: Decimal { Decimal(micros) / 1_000_000 }

        enum CodingKeys: String, CodingKey {
            case micros = "balance_micros"
            case topUpURL = "top_up_url"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            micros = try container.decode(Int.self, forKey: .micros)
            // A link that is not a URL is no link: the balance is still worth showing.
            topUpURL = (try? container.decodeIfPresent(String.self, forKey: .topUpURL)).flatMap { $0.flatMap(URL.init(string:)) }
        }
    }

    /// The balance of the key, from the gateway. An error answer (wrong key, disabled key) throws
    /// `ChatClient.Failure.http` with the gateway's message.
    public static func balance(apiKey: String, transport: ChatClient.Transport) async throws -> Balance {
        var request = URLRequest(url: URL(string: baseURL)!.appending(path: "balance"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ChatClient.Failure.http(status: response.statusCode, message: ChatClient.errorMessage(in: data))
        }
        return try JSONDecoder().decode(Balance.self, from: data)
    }
}

extension ProviderProfile {
    /// The Profile of Takku Credit, waiting for its key.
    public static func takkuCredit() -> ProviderProfile {
        ProviderProfile(
            name: "Takku Credit", baseURL: TakkuCredit.baseURL, model: TakkuCredit.model,
            maxContextTokens: TakkuCredit.maxContextTokens
        )
    }

    /// Recognised by its address, not by its name, which the user may change.
    public var isTakkuCredit: Bool {
        URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host()?.lowercased() == TakkuCredit.host
    }
}
