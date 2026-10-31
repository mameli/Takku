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

    /// A pack to add credit: its price and the Payment Link with this key's public id, so that
    /// whatever email is typed at checkout, the payment tops up this key.
    public struct Pack: Equatable, Sendable {
        public let priceEuros: Decimal
        public let url: URL
        public let isRecommended: Bool

        public init(priceEuros: Decimal, url: URL, isRecommended: Bool = false) {
            self.priceEuros = priceEuros
            self.url = url
            self.isRecommended = isRecommended
        }

        private struct Raw: Decodable {
            let price_eur: Decimal
            let url: String
            let recommended: Bool?
        }

        /// The packs under `key`, by price. One that cannot be read is left out: what else the
        /// answer says is still worth showing.
        fileprivate static func list<Key: CodingKey>(in container: KeyedDecodingContainer<Key>, forKey key: Key) -> [Pack] {
            let raw = (try? container.decodeIfPresent([LossyRaw].self, forKey: key)) ?? nil
            return (raw ?? [])
                .compactMap { lossy in
                    lossy.pack.flatMap { pack in
                        URL(string: pack.url).map { Pack(priceEuros: pack.price_eur, url: $0, isRecommended: pack.recommended == true) }
                    }
                }
                .sorted { $0.priceEuros < $1.priceEuros }
        }

        /// One pack, or nothing when it cannot be read, so that one bad pack does not hide the others.
        private struct LossyRaw: Decodable {
            let pack: Raw?
            init(from decoder: Decoder) throws { pack = try? Raw(from: decoder) }
        }
    }

    /// What `GET /v1/balance` answers. Money is in micro-euros (1 € = 1,000,000), as the gateway keeps it.
    public struct Balance: Decodable, Equatable, Sendable {
        public let micros: Int
        /// By price; none when the gateway has no links yet.
        public let packs: [Pack]

        /// The pack the single button buys: the recommended one, or the first.
        public var recommendedPack: Pack? { packs.first(where: \.isRecommended) ?? packs.first }

        public init(micros: Int, packs: [Pack]) {
            self.micros = micros
            self.packs = packs
        }

        public var euros: Decimal { Decimal(micros) / 1_000_000 }

        enum CodingKeys: String, CodingKey {
            case micros = "balance_micros"
            case packs
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            micros = try container.decode(Int.self, forKey: .micros)
            packs = Pack.list(in: container, forKey: .packs)
        }
    }

    /// What `GET /v1/packs` answers.
    private struct PackList: Decodable {
        let packs: [Pack]

        enum CodingKeys: String, CodingKey { case packs }

        init(from decoder: Decoder) throws {
            packs = Pack.list(in: try decoder.container(keyedBy: CodingKeys.self), forKey: .packs)
        }
    }

    /// The packs for someone with no key yet, with the plain links: the payment makes a new key and
    /// emails it (or tops up the key of the email typed at checkout). Asked with no key.
    public static func packs(transport: ChatClient.Transport) async throws -> [Pack] {
        let (data, response) = try await transport(URLRequest(url: URL(string: baseURL)!.appending(path: "packs")))
        guard (200..<300).contains(response.statusCode) else {
            throw ChatClient.Failure.http(status: response.statusCode, message: ChatClient.errorMessage(in: data))
        }
        return try JSONDecoder().decode(PackList.self, from: data).packs
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
