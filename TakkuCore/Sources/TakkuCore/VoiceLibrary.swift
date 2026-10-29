import Foundation

/// The voices the user named in past Meetings, kept on this Mac to suggest a name for the Speakers
/// of the next ones (ADR 0006). A voice is a speaker embedding: numbers that are close for the same
/// voice and far apart for different ones. They are biometric data: Takku keeps them only while the
/// user has voice recognition on, and every name can be forgotten.
public struct VoiceLibrary: Codable, Equatable, Sendable {
    public struct Voice: Codable, Equatable, Sendable {
        public let name: String
        /// One embedding per Meeting the name was given in, the latest last.
        public fileprivate(set) var heard: [Heard]

        public var updated: Date? { heard.last?.date }
    }

    public struct Heard: Codable, Equatable, Sendable {
        public let meeting: UUID
        public let date: Date
        public let embedding: [Float]
    }

    public private(set) var voices: [Voice] = []

    /// Meetings kept per name: enough to cover other microphones and rooms, few enough that a
    /// voice heard long ago gives way.
    static let meetingsPerName = 5
    /// Cosine distance under which a Speaker is taken for a known voice. On 13 real Meetings two
    /// different Speakers of the same Meeting were under it once in 179 pairs (under 0.6, 32
    /// times); the user's own voice across Meetings was at 0.33 in the median. A wrong name is
    /// worse than none: some voices will not be recognised.
    public static let matchDistance: Float = 0.4

    public init() {}

    /// Remembers the voices named in a Meeting, in place of what this Meeting had taught before:
    /// naming the Speakers again (a name corrected, one removed) does not count the Meeting twice.
    /// Two Speakers given the same name are one voice split in two by diarization.
    public mutating func remember(
        names: [Int: String], embeddings: [Int: [Float]], meeting: UUID, at date: Date = .now
    ) {
        for index in voices.indices { voices[index].heard.removeAll { $0.meeting == meeting } }
        var byName: [String: [[Float]]] = [:]
        for (speaker, name) in names {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let embedding = embeddings[speaker] else { continue }
            byName[existingName(name) ?? name, default: []].append(embedding)
        }
        for (name, embeddings) in byName {
            guard let embedding = Self.mean(embeddings) else { continue }
            let heard = Heard(meeting: meeting, date: date, embedding: embedding)
            if let index = voices.firstIndex(where: { $0.name == name }) {
                voices[index].heard.append(heard)
                voices[index].heard.sort { $0.date < $1.date }
                voices[index].heard = Array(voices[index].heard.suffix(Self.meetingsPerName))
            } else {
                voices.append(Voice(name: name, heard: [heard]))
            }
        }
        voices.removeAll { $0.heard.isEmpty }
        voices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public mutating func forget(_ name: String) {
        voices.removeAll { $0.name == name }
    }

    /// A known name for each Speaker whose voice is close enough to one, the closest pairs first,
    /// so a name goes to one Speaker only.
    public func suggestions(for embeddings: [Int: [Float]]) -> [Int: String] {
        let known = voices.compactMap { voice in Self.mean(voice.heard.map(\.embedding)).map { (voice.name, $0) } }
        var pairs: [(speaker: Int, name: String, distance: Float)] = []
        for (speaker, embedding) in embeddings {
            for (name, voice) in known {
                if let distance = Self.distance(embedding, voice), distance < Self.matchDistance {
                    pairs.append((speaker, name, distance))
                }
            }
        }
        var suggestions: [Int: String] = [:]
        for pair in pairs.sorted(by: { ($0.distance, $0.speaker) < ($1.distance, $1.speaker) })
        where suggestions[pair.speaker] == nil && !suggestions.values.contains(pair.name) {
            suggestions[pair.speaker] = pair.name
        }
        return suggestions
    }

    /// The direction the embeddings share, of length 1; `nil` without any usable one.
    public static func mean(_ embeddings: [[Float]]) -> [Float]? {
        guard let size = embeddings.first?.count, size > 0 else { return nil }
        let usable = embeddings.filter { $0.count == size }.compactMap(normalized)
        guard !usable.isEmpty else { return nil }
        var sum = [Float](repeating: 0, count: size)
        for embedding in usable {
            for index in sum.indices { sum[index] += embedding[index] }
        }
        return normalized(sum)
    }

    /// 0 for the same direction, 2 for opposite ones; `nil` if they cannot be compared.
    static func distance(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, let a = normalized(a), let b = normalized(b) else { return nil }
        return 1 - zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private static func normalized(_ vector: [Float]) -> [Float]? {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0, length.isFinite else { return nil }
        return vector.map { $0 / length }
    }

    /// The name as already written, if it is known with other capitals or accents left out.
    private func existingName(_ name: String) -> String? {
        voices.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }?.name
    }
}
