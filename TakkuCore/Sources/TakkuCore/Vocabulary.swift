import Foundation

/// The terms speech recognition gets wrong, read from `~/.takku/vocabulary.md`: each entry is the
/// correct term, optionally with the variants usually heard instead and a short description.
public struct Vocabulary: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let term: String
        public let variants: [String]
        public let description: String?

        public init(term: String, variants: [String] = [], description: String? = nil) {
            self.term = term
            self.variants = variants
            self.description = description
        }
    }

    public static let empty = Vocabulary(fileContent: "")

    /// What Takku writes when the user opens the Vocabulary and the file does not exist yet. The
    /// examples sit inside lines of text, so nothing in it counts until the user adds list items.
    public static let exampleFileContent = """
        # Vocabulary

        Names, acronyms and technical words that speech recognition gets wrong. Takku uses them in the Summary and fixes the variants in the Transcript.

        One entry per line, starting with `- `: the correct term, then after `=` the variants usually heard instead (optional, comma-separated), then after `|` a short description (optional). Example: `- Scaleway = scale uai | our EU cloud provider`

        Lines that are not entries, like this text, are ignored.

        """

    public let entries: [Entry]

    /// Variants of a term shown to the model, the first ones of its line.
    static let promptVariants = 3

    public init(fileContent: String) {
        var seenTerms = Set<String>()
        var seenVariants = Set<String>()
        var entries: [Entry] = []
        for line in fileContent.split(whereSeparator: \.isNewline) where line.hasPrefix("- ") {
            let (rest, description) = Self.split(line.dropFirst(2), on: "|")
            let (term, variants) = Self.split(rest, on: "=")
            // The first entry counts, for a term and for a variant.
            guard !term.isEmpty, seenTerms.insert(term.lowercased()).inserted else { continue }
            let kept = (variants?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? [])
                .filter { !$0.isEmpty && $0 != term && seenVariants.insert($0.lowercased()).inserted }
            entries.append(Entry(term: term, variants: kept, description: description?.isEmpty == true ? nil : description))
        }
        self.entries = entries
    }

    /// What the system prompt of a request carries about the Vocabulary: the terms with their
    /// description and variants, and the rule for using them. `nil` if there are no entries.
    /// A listed variant is certain: told only to correct when sure, the model left "Carpenter" next to
    /// "Karpenter = Carpenter". A term nobody said is not: it once turned up in a Summary by association.
    /// The Transcript the model reads has every variant replaced already: the first `promptVariants`
    /// only show how a term gets misheard, the rest made the Vocabulary most of the system message.
    var promptBlock: String? {
        guard !entries.isEmpty else { return nil }
        let lines = entries.map { entry in
            var line = "- \(entry.term)"
            if let description = entry.description { line += ": \(description)" }
            if !entry.variants.isEmpty {
                let shown = entry.variants.prefix(Self.promptVariants)
                line += " (may be written as \(shown.map { "\"\($0)\"" }.joined(separator: ", ")))"
            }
            return line
        }
        return """
            Vocabulary, the names and technical terms of this person's meetings:
            \(lines.joined(separator: "\n"))
            The Transcript comes from automatic speech recognition and may spell names and technical terms wrong. \
            A word written as one of the variants listed above is that term: always write the term. \
            For other words use the Vocabulary and the context to write them right, but correct a word only when you are sure; \
            otherwise leave it as it is. Do not bring in a term that nobody said.
            """
    }

    /// A function that replaces every known variant in a text with its term. One pass over the
    /// text with all the variants, longest first, so the longest one wins and a replacement is
    /// never replaced again. Built once and applied to many texts.
    func variantReplacer() -> (String) -> String {
        var termFor: [String: String] = [:]
        for entry in entries {
            for variant in entry.variants { termFor[variant.lowercased()] = entry.term }
        }
        let alternatives = termFor.keys.sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        // Letters and digits next to a variant stop the match: whole words only.
        guard !alternatives.isEmpty,
              let regex = try? NSRegularExpression(
                  pattern: "(?<![\\p{L}\\p{N}])(?:\(alternatives))(?![\\p{L}\\p{N}])", options: .caseInsensitive
              )
        else { return { $0 } }

        return { text in
            var output = ""
            var cursor = text.startIndex
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                output += text[cursor..<range.lowerBound]
                output += termFor[text[range].lowercased()] ?? String(text[range])
                cursor = range.upperBound
            }
            return output + text[cursor...]
        }
    }

    /// The text before the first `separator`, trimmed, and the trimmed text after it, if any.
    private static func split(_ text: some StringProtocol, on separator: Character) -> (String, String?) {
        guard let index = text.firstIndex(of: separator) else {
            return (text.trimmingCharacters(in: .whitespaces), nil)
        }
        return (
            text[..<index].trimmingCharacters(in: .whitespaces),
            text[text.index(after: index)...].trimmingCharacters(in: .whitespaces)
        )
    }
}
