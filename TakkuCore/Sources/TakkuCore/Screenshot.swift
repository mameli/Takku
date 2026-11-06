import Foundation

/// An image of the screen taken while recording, kept in the Vault and shown in the Transcript and
/// the Meeting note. The Summary model never sees it, nor its name (ADR 0011).
public struct Screenshot: Equatable, Sendable {
    /// The folder in the Recording folder where they are saved as soon as they are taken.
    public static let folderName = "screenshots"
    public static let fileExtension = "jpg"
    /// Width in the Summary, where a full-size image would break up the points; a click enlarges it.
    static let summaryWidth = 400

    /// What goes inside `![[…]]`: the file name, possibly with Obsidian's `|size`.
    public let embed: String
    /// Seconds from the start of the Meeting.
    public let time: TimeInterval

    public init(embed: String, time: TimeInterval) {
        self.embed = embed
        self.time = time
    }

    /// The file name in `embed`, without Obsidian's `|size`.
    public var fileName: String {
        String(embed.prefix { $0 != "|" })
    }

    /// The Screenshot named the way Takku names them; `nil` for any other name.
    public init?(fileName: String) {
        guard let time = Self.time(inName: fileName) else { return nil }
        self.init(embed: fileName, time: time)
    }

    /// `2026-10-04 1430 - 12m30s`, without extension: the Meeting start, then the time from it.
    public static func baseName(startedAt: Date, time: TimeInterval, timeZone: TimeZone = .current) -> String {
        let total = max(0, Int(exactly: time.rounded(.towardZero)) ?? 0)
        let (hours, minutes, seconds) = (total / 3600, total % 3600 / 60, total % 60)
        let elapsed = hours > 0
            ? String(format: "%dh%02dm%02ds", hours, minutes, seconds)
            : String(format: "%dm%02ds", minutes, seconds)
        return "\(DateFormatter.posix("yyyy-MM-dd HHmm", timeZone: timeZone).string(from: startedAt)) - \(elapsed)"
    }

    /// The Screenshots saved in a Recording folder, in time order; none if there are none.
    public static func load(fromFolder folder: URL) -> [Screenshot] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder.appending(path: folderName, directoryHint: .isDirectory), includingPropertiesForKeys: nil
        )) ?? []
        return files.compactMap { Screenshot(fileName: $0.lastPathComponent) }.sorted(by: Self.inTimeOrder)
    }

    /// The Screenshot a Transcript line embeds, if the line is only an image embed:
    /// `![[name.jpg]]` or `![[name.png|300]]`. `fallbackTime` for a name not made by Takku.
    static func embedded(in line: String, fallbackTime: TimeInterval) -> Screenshot? {
        guard let match = line.wholeMatch(of: /!\[\[([^\[\]|]+\.(?i:jpe?g|png|webp|gif))(\|[^\[\]]*)?\]\]/) else {
            return nil
        }
        return Screenshot(embed: String(match.1) + String(match.2 ?? ""), time: time(inName: String(match.1)) ?? fallbackTime)
    }

    /// The model's reply with each Screenshot, smaller, on its own line under the first line citing the
    /// paragraph it falls in (its start, or a range with it), indented to stay in that point. The model
    /// never sees them: the times it cites for every point are enough to place them. A Screenshot no
    /// line cites, or taken before any speech, is not placed.
    static func placing(_ screenshots: [Screenshot], in reply: String, paragraphs: [Paragraph]) -> String {
        var lines = reply.components(separatedBy: "\n")
        var below: [Int: [Screenshot]] = [:]
        for screenshot in screenshots.sorted(by: inTimeOrder) {
            guard let paragraph = paragraphs.last(where: { $0.start <= screenshot.time }) else { continue }
            let start = Int(paragraph.start)
            if let line = lines.firstIndex(where: { citedTimes(in: $0).contains { $0.contains(start) } }) {
                below[line, default: []].append(screenshot)
            }
        }
        for (line, placed) in below.sorted(by: { $0.key > $1.key }) {
            let indent = continuationIndent(of: lines[line])
            lines.insert(contentsOf: placed.map { "\(indent)![[\($0.fileName)|\(summaryWidth)]]" }, at: line + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// The times a line cites, as the prompt asks them (`[12:34]`, `[03:10] [07:45]`, `[04:00-06:30]`), in seconds.
    private static func citedTimes(in line: String) -> [ClosedRange<Int>] {
        let time = /\d{1,2}(?::\d{2}){1,2}/
        func seconds(_ text: Substring) -> Int {
            text.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
        }
        return line.matches(of: /\[([\d:\s,;\-–—]+)\]/).flatMap { bracket in
            bracket.1.split(whereSeparator: { ",;".contains($0) }).compactMap { part -> ClosedRange<Int>? in
                let times = part.matches(of: time).map { seconds($0.output) }
                guard let first = times.first else { return nil }
                return min(first, times.last!)...max(first, times.last!)
            }
        }
    }

    /// What a line under `line` needs in front to belong to it: the indentation of its text for a list
    /// item (`- `, `- [ ] `, `1. `), its own indentation otherwise.
    private static func continuationIndent(of line: String) -> String {
        let leading = String(line.prefix { $0 == " " || $0 == "\t" })
        guard let marker = line.dropFirst(leading.count).prefixMatch(of: /(?:[-*+]|\d+[.)])[ \t]+/) else { return leading }
        return leading + String(repeating: " ", count: marker.output.count)
    }

    static func inTimeOrder(_ lhs: Screenshot, _ rhs: Screenshot) -> Bool {
        (lhs.time, lhs.embed) < (rhs.time, rhs.embed)
    }

    /// The time in a name made by `baseName`, with or without the ` (2)` suffix and the extension.
    private static func time(inName name: String) -> TimeInterval? {
        let pattern = /\d{4}-\d{2}-\d{2} \d{4} - (?:(\d{1,4})h)?(\d{1,4})m(\d{2})s(?: \(\d+\))?\.jpg/
        guard let match = name.wholeMatch(of: pattern) else { return nil }
        let hours = match.1.flatMap { Double($0) } ?? 0
        return hours * 3600 + (Double(match.2) ?? 0) * 60 + (Double(match.3) ?? 0)
    }
}
