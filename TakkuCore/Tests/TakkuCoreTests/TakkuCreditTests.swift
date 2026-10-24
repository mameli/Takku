import Foundation
import Testing
import TakkuCore

@Suite("Takku Credit")
struct TakkuCreditTests {
    func profile(_ baseURL: String) -> ProviderProfile {
        ProviderProfile(name: "Renamed", baseURL: baseURL, model: "m", maxContextTokens: 32_000)
    }

    @Test("its Profile is recognised by the address, whatever its name", arguments: [
        ("https://api.takku.app/v1", true), (" https://API.takku.app/v1 ", true), ("https://api.takku.app", true),
        ("https://takku.app/v1", false), ("https://api.takku.app.example.com/v1", false), ("https://api.tensorx.ai/v1", false), ("", false),
    ])
    func recognised(baseURL: String, isTakkuCredit: Bool) {
        #expect(profile(baseURL).isTakkuCredit == isTakkuCredit)
    }

    @Test("the ready-made Profile is https, with the gateway's model and context")
    func readyMade() throws {
        let credit = ProviderProfile.takkuCredit()
        #expect(credit.isTakkuCredit)
        #expect(try credit.validatedBaseURL().absoluteString == "https://api.takku.app/v1")
        #expect(credit.model == "takku-summary")
        #expect(credit.maxContextTokens == 128_000)
        #expect(credit.reasoning == nil && credit.extraParameters == nil)
    }

    /// Answers every request with `status` and `body`, and keeps the last request.
    final class Gateway: @unchecked Sendable {
        var request: URLRequest?
        let status: Int
        let body: String
        init(status: Int, body: String) {
            self.status = status
            self.body = body
        }

        var transport: ChatClient.Transport {
            { request in
                self.request = request
                return (Data(self.body.utf8), HTTPURLResponse(url: request.url!, statusCode: self.status, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    @Test("the balance is read with the key, in euros, with the packs by price and the recommended one")
    func balance() async throws {
        let body = #"{"balance_micros":8190004,"balance_eur":8.190004,"account_id":"ta_x","packs":[{"price_eur":5,"url":"https://buy.stripe.com/five?client_reference_id=ta_x","recommended":false},{"price_eur":10,"url":"https://buy.stripe.com/ten?client_reference_id=ta_x","recommended":true},{"price_eur":20,"url":"https://buy.stripe.com/twenty?client_reference_id=ta_x","recommended":false}],"top_up_url":"https://buy.stripe.com/ten?client_reference_id=ta_x"}"#
        let gateway = Gateway(status: 200, body: body)
        let balance = try await TakkuCredit.balance(apiKey: "tk_secret", transport: gateway.transport)
        #expect(balance.micros == 8_190_004)
        #expect(balance.euros == Decimal(string: "8.190004"))
        #expect(balance.packs.map(\.priceEuros) == [5, 10, 20])
        #expect(balance.recommendedPack?.url == URL(string: "https://buy.stripe.com/ten?client_reference_id=ta_x"))
        #expect(gateway.request?.url == URL(string: "https://api.takku.app/v1/balance"))
        #expect(gateway.request?.value(forHTTPHeaderField: "Authorization") == "Bearer tk_secret")
        #expect(gateway.request?.httpMethod == "GET")
    }

    @Test("without packs the balance is still read, and without a recommended one the first is used")
    func noPacks() async throws {
        let none = Gateway(status: 200, body: #"{"balance_micros":-1200,"account_id":"ta_x","packs":[],"top_up_url":null}"#)
        let balance = try await TakkuCredit.balance(apiKey: "tk_secret", transport: none.transport)
        #expect(balance == TakkuCredit.Balance(micros: -1200, packs: []))
        #expect(balance.recommendedPack == nil)
        let five = TakkuCredit.Pack(priceEuros: 5, url: URL(string: "https://buy.stripe.com/five")!)
        #expect(TakkuCredit.Balance(micros: 1, packs: [five]).recommendedPack == five)
    }

    @Test("credit used up says what to do; a 402 from another provider is its own message")
    func noCredit() async {
        let body = #"{"error":{"message":"No credit left.","type":"takku_gateway","code":"insufficient_credit"}}"#
        let gateway = Gateway(status: 402, body: body)
        let credit = ChatClient(baseURL: URL(string: TakkuCredit.baseURL)!, apiKey: "tk_x", model: TakkuCredit.model, transport: gateway.transport)
        await #expect(throws: ChatClient.Failure.noCredit) { try await credit.complete([ChatMessage(role: .user, content: "Hi")]) }

        let other = ChatClient(baseURL: URL(string: "https://openrouter.ai/api/v1")!, apiKey: "sk", model: "m", transport: gateway.transport)
        await #expect(throws: ChatClient.Failure.http(status: 402, message: "No credit left.")) {
            try await other.complete([ChatMessage(role: .user, content: "Hi")])
        }
    }

    @Test("a refused key gives the gateway's message")
    func refused() async {
        let gateway = Gateway(status: 401, body: #"{"error":{"message":"This API key is not valid.","type":"takku_gateway","code":"invalid_api_key"}}"#)
        await #expect(throws: ChatClient.Failure.http(status: 401, message: "This API key is not valid.")) {
            try await TakkuCredit.balance(apiKey: "tk_wrong", transport: gateway.transport)
        }
    }
}
