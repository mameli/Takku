import Testing
import TakkuCore

@Suite("Meeting languages")
struct MeetingLanguagesTests {
    @Test("languages are kept in the Settings order, once, and only if offered")
    func normalized() {
        #expect(MeetingLanguages.normalized(["fr", "en", "fr", "xx", "it"]) == ["it", "en", "fr"])
        #expect(MeetingLanguages.normalized(["de", "es"]) == ["de", "es"])
    }

    @Test("with nothing valid ticked, Italian and English as in v1")
    func emptyFallsBackToDefaults() {
        #expect(MeetingLanguages.normalized([]) == ["it", "en"])
        #expect(MeetingLanguages.normalized(["xx"]) == ["it", "en"])
    }

    @Test("a single language ticked is forced; several are detected")
    func forced() {
        #expect(MeetingLanguages.forced(["fr"]) == "fr")
        #expect(MeetingLanguages.forced(["it", "en"]) == nil)
        #expect(MeetingLanguages.forced([]) == nil)
    }

    @Test("when nothing is detected the first ticked language is used, Italian first")
    func fallback() {
        #expect(MeetingLanguages.fallback(["en", "it"]) == "it")
        #expect(MeetingLanguages.fallback(["fr", "en"]) == "en")
        #expect(MeetingLanguages.fallback(["fr", "de"]) == "fr")
    }

    @Test("by default the Mac's languages Takku offers, and English")
    func defaults() {
        #expect(MeetingLanguages.defaults(macLanguages: ["es-ES"]) == ["en", "es"])
        #expect(MeetingLanguages.defaults(macLanguages: ["it-IT", "en-GB"]) == ["it", "en"])
        #expect(MeetingLanguages.defaults(macLanguages: ["fr", "de-CH", "zh-Hans-CN"]) == ["en", "fr", "de"])
        #expect(MeetingLanguages.defaults(macLanguages: ["en-US"]) == ["en"])
        #expect(MeetingLanguages.defaults(macLanguages: []) == ["en"])
    }

    @Test("a Takku set up before keeps the v1 language setting, the Mac's languages added to Italian and English")
    func migrated() {
        #expect(MeetingLanguages.migrated(fromLanguageSetting: "it", macLanguages: ["es-ES"]) == ["it"])
        #expect(MeetingLanguages.migrated(fromLanguageSetting: "en", macLanguages: ["es-ES"]) == ["en"])
        #expect(MeetingLanguages.migrated(fromLanguageSetting: "auto", macLanguages: ["it-IT"]) == ["it", "en"])
        #expect(MeetingLanguages.migrated(fromLanguageSetting: nil, macLanguages: ["es-ES", "it-IT"]) == ["it", "en", "es"])
        #expect(MeetingLanguages.migrated(fromLanguageSetting: nil, macLanguages: []) == ["it", "en"])
    }
}
