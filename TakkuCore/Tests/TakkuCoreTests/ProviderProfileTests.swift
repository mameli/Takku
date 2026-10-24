import Foundation
import Testing
import TakkuCore

@Suite("Checking a Profile's base URL")
struct ProviderProfileTests {
    func profile(_ baseURL: String) -> ProviderProfile {
        ProviderProfile(name: "Test", baseURL: baseURL, model: "m", maxContextTokens: 32_000)
    }

    @Test("https is accepted anywhere, plain http only for servers on this Mac", arguments: [
        "https://api.mistral.ai/v1", "http://localhost:8080/v1", "http://127.0.0.1:8080/v1", "http://[::1]:8080/v1",
        " https://api.regolo.ai/v1 ",
    ])
    func accepted(baseURL: String) throws {
        #expect(try profile(baseURL).validatedBaseURL().scheme != nil)
    }

    @Test("plain http to another machine is refused: key and Transcript would travel readable", arguments: [
        "http://api.mistral.ai/v1", "http://server.local:8080/v1", "http://192.168.1.20:8080/v1",
    ])
    func insecure(baseURL: String) {
        #expect(throws: ProviderProfile.URLError.insecure(baseURL)) { try profile(baseURL).validatedBaseURL() }
    }

    @Test("an address without scheme or host is refused", arguments: ["", "api.mistral.ai/v1", "ftp://x.eu/v1", "https://"])
    func invalid(baseURL: String) {
        #expect(throws: ProviderProfile.URLError.invalid(baseURL)) { try profile(baseURL).validatedBaseURL() }
    }

    @Test("a Profile saved before the reasoning option loads with the model's default and no Extra parameters")
    func savedWithoutReasoning() throws {
        let saved = #"{"id":"6A1C1F0E-2B7D-4C4B-9E61-3F0F2E5B9A10","name":"OpenRouter","baseURL":"https://openrouter.ai/api/v1","model":"m","maxContextTokens":128000}"#
        let profile = try JSONDecoder().decode(ProviderProfile.self, from: Data(saved.utf8))
        #expect(profile.reasoning == nil)
        #expect(profile.extraParameters == nil)
        #expect(profile.maxContextTokens == 128_000)
    }

    @Test("Extra parameters are a JSON object; blank means none", arguments: [
        ("", 0), (" \n ", 0), (#"{}"#, 0), (#"{"chat_template_kwargs": {"thinking": true}, "temperature": 0.2}"#, 2),
    ])
    func extraParameters(text: String, count: Int) throws {
        #expect(try ExtraParameters.parse(text).count == count)
    }

    @Test("Extra parameters that are not a JSON object, or that replace model or messages, are refused", arguments: [
        (#"{"reasoning_effort": "xhigh""#, ExtraParameters.Problem.notJSON),
        (#"{“reasoning_effort”: “xhigh”}"#, .notJSON),
        (#"[{"thinking": true}]"#, .notAnObject),
        ("42", .notAnObject),
        (#"{"model": "other"}"#, .reserved("model")),
        (#"{"messages": []}"#, .reserved("messages")),
    ])
    func invalidExtraParameters(text: String, problem: ExtraParameters.Problem) {
        #expect(throws: problem) { try ExtraParameters.parse(text) }
    }

    @Test("the ready-made Profiles: Takku Credit first, Ollama on this Mac, then Mistral, TensorX and OpenRouter over https")
    func readyMade() throws {
        let profiles = ProviderProfile.readyMade()
        #expect(profiles.map(\.name) == ["Takku Credit", "Ollama", "Mistral", "TensorX", "OpenRouter"])
        #expect(profiles.map(\.runsOnThisMac) == [false, true, false, false, false])
        #expect(profiles.map(\.isTakkuCredit) == [true, false, false, false, false])
        for profile in profiles {
            #expect(try profile.validatedBaseURL().scheme == (profile.runsOnThisMac ? "http" : "https"))
            #expect(!profile.model.isEmpty)
            #expect(profile.maxContextTokens >= ProviderProfile.defaultMaxContextTokens)
        }
        #expect(Set(profiles.map(\.id)).isDisjoint(with: ProviderProfile.readyMade().map(\.id)))
    }
}
