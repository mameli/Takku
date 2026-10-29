import Foundation
import Testing
@testable import TakkuCore

@Suite("Voices remembered to suggest Speaker names")
struct VoiceLibraryTests {
    private let mario: [Float] = [1, 0, 0, 0]
    private let luca: [Float] = [0, 1, 0, 0]
    private let first = UUID()
    private let second = UUID()

    @Test("a named voice is suggested for a close one, an unknown voice gets no name")
    func suggestions() {
        var library = VoiceLibrary()
        library.remember(names: [1: "Mario Rossi", 2: "Luca"], embeddings: [1: mario, 2: luca], meeting: first)

        #expect(library.suggestions(for: [3: [0.95, 0.1, 0.05, 0], 4: [0, 0, 1, 0]]) == [3: "Mario Rossi"])
    }

    @Test("a name goes to the closest Speaker only")
    func oneSpeakerPerName() {
        var library = VoiceLibrary()
        library.remember(names: [1: "Mario Rossi"], embeddings: [1: mario], meeting: first)

        #expect(library.suggestions(for: [1: [0.8, 0.3, 0, 0], 2: [0.95, 0.1, 0, 0]]) == [2: "Mario Rossi"])
    }

    @Test("naming a Meeting again replaces what it taught, a name left without Meetings is gone")
    func renamingReplaces() {
        var library = VoiceLibrary()
        library.remember(names: [1: "Mario"], embeddings: [1: mario], meeting: first)
        library.remember(names: [1: "Mario Rossi"], embeddings: [1: mario], meeting: first)

        #expect(library.voices.map(\.name) == ["Mario Rossi"])
        #expect(library.voices[0].heard.count == 1)
    }

    @Test("Speakers without a name or without a voice teach nothing; capitals and spaces do not make a new name")
    func onlyNamedVoices() {
        var library = VoiceLibrary()
        library.remember(names: [1: "Mario Rossi"], embeddings: [1: mario], meeting: first)
        library.remember(
            names: [1: " mario rossi ", 2: "", 3: "Luca"], embeddings: [1: mario, 2: luca], meeting: second
        )

        #expect(library.voices.map(\.name) == ["Mario Rossi"])
        #expect(library.voices[0].heard.map(\.meeting) == [first, second])
    }

    @Test("two Speakers with the same name are one voice")
    func splitVoice() throws {
        var library = VoiceLibrary()
        library.remember(names: [1: "Mario Rossi", 2: "Mario Rossi"], embeddings: [1: mario, 2: [1, 0.2, 0, 0]], meeting: first)

        let heard = try #require(library.voices.first?.heard)
        #expect(heard.count == 1)
        #expect(heard[0].embedding[1] > 0)
    }

    @Test("only the latest Meetings of a name are kept")
    func latestMeetings() {
        var library = VoiceLibrary()
        for day in 0..<7 {
            library.remember(
                names: [1: "Mario Rossi"], embeddings: [1: mario], meeting: UUID(),
                at: Date(timeIntervalSince1970: Double(day) * 86_400)
            )
        }

        #expect(library.voices[0].heard.count == VoiceLibrary.meetingsPerName)
        #expect(library.voices[0].updated == Date(timeIntervalSince1970: 6 * 86_400))
    }

    @Test("a forgotten name is no longer suggested")
    func forget() {
        var library = VoiceLibrary()
        library.remember(names: [1: "Mario Rossi"], embeddings: [1: mario], meeting: first)
        library.forget("Mario Rossi")

        #expect(library.voices.isEmpty)
        #expect(library.suggestions(for: [1: mario]).isEmpty)
    }

    @Test("embeddings of another size or all zeros are left out")
    func unusableEmbeddings() {
        #expect(VoiceLibrary.mean([]) == nil)
        #expect(VoiceLibrary.mean([[0, 0]]) == nil)
        #expect(VoiceLibrary.mean([[2, 0], [0, 0], [1, 0, 0]]) == [1, 0])
        #expect(VoiceLibrary.distance([1, 0], [1, 0, 0]) == nil)
    }
}
