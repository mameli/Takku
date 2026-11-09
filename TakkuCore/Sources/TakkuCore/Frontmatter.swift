import Foundation

/// The lines of a Markdown file, normalised (no BOM, `\n` line endings), with the
/// position of its YAML frontmatter.
struct MarkdownLines {
    var lines: [String]

    init(_ content: String) {
        var normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        lines = normalized.components(separatedBy: "\n")
    }

    var text: String { lines.joined(separator: "\n") }

    /// Index of the line that closes the frontmatter, `nil` if the file has none.
    var frontmatterClose: Int? {
        guard let first = lines.first, Self.isLine(first, "---") else { return nil }
        return lines.indices.dropFirst().first { Self.isLine(lines[$0], "---") }
    }

    /// Index of the first line after the frontmatter (0 without frontmatter).
    var bodyStart: Int {
        frontmatterClose.map { $0 + 1 } ?? 0
    }

    /// Value of a top-level `key: value` line of the frontmatter.
    func value(_ key: String) -> String? {
        guard let close = frontmatterClose,
              let line = lines[1..<close].first(where: { $0.hasPrefix("\(key):") })
        else { return nil }
        return line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// Items of a top-level list of the frontmatter, written as a block (`- item` lines under the key)
    /// or inline (`[a, b]`); a single value counts as one item. `nil` if the key is missing.
    func list(_ key: String) -> [String]? {
        guard let close = frontmatterClose,
              let line = lines[1..<close].firstIndex(where: { $0.hasPrefix("\(key):") })
        else { return nil }
        let inline = lines[line].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        if inline.hasPrefix("["), inline.hasSuffix("]") {
            return inline.dropFirst().dropLast().split(separator: ",").map { Self.unquoted(String($0)) }.filter { !$0.isEmpty }
        }
        if !inline.isEmpty { return [Self.unquoted(inline)] }
        var items: [String] = []
        for item in lines[(line + 1)..<close] {
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-") else { break }
            let value = Self.unquoted(String(trimmed.dropFirst()))
            if !value.isEmpty { items.append(value) }
        }
        return items
    }

    private static func unquoted(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        for quote in ["\"", "'"] where trimmed.count >= 2 && trimmed.hasPrefix(quote) && trimmed.hasSuffix(quote) {
            return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        return trimmed
    }

    static func isLine(_ line: String, _ text: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == text
    }

    /// The frontmatter of the file at `url` without the text after it; `nil` if the file cannot be
    /// read or has none. Read in pieces from the start, up to the line that closes it: looking for
    /// a Meeting by its `takku_id` goes through every Transcript of the notes folder, tens of KB
    /// each after a few lines of frontmatter (1,000 of an hour each took 2.5 s read whole, 0.13 s
    /// this way). Only the frontmatter is decoded: text after it that is not UTF-8 does not hide the file.
    static func frontmatter(ofFileAt url: URL) -> MarkdownLines? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        var head = Data()
        var pieceSize = 1_024
        while true {
            let piece: Data
            do { piece = try file.read(upToCount: pieceSize) ?? Data() } catch { return nil }
            let isEnd = piece.isEmpty
            head.append(piece)
            var markdown = MarkdownLines(String(decoding: head, as: UTF8.self))
            // Before the end of the file the last line may be cut, inside a character too.
            if !isEnd { markdown.lines.removeLast() }
            if let first = markdown.lines.first, !isLine(first, "---") { return nil }
            if let close = markdown.frontmatterClose {
                markdown.lines.removeSubrange((close + 1)...)
                return markdown
            }
            if isEnd { return nil }
            pieceSize *= 4
        }
    }
}
