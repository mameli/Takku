import Foundation

/// Names of the files Takku writes in the Vault (without the `.md` extension).
public enum VaultNaming {
    public static let defaultTitle = "Meeting"

    /// Characters Obsidian does not accept in file names or that break `[[…]]` links.
    private static let forbidden = CharacterSet(charactersIn: "*\"\\/<>:|?#^[]")

    public static func noteName(startedAt: Date, title: String, timeZone: TimeZone = .current) -> String {
        "\(DateFormatter.posix("yyyy-MM-dd HHmm", timeZone: timeZone).string(from: startedAt)) - \(sanitized(title))"
    }

    /// The new name of the Meeting note with `title`, or `nil` if the user already renamed it: it no
    /// longer has the name Takku gave it with `previousTitle` (the provisional one, or the calendar
    /// event's when the user picks another event), possibly with a " (n)" suffix.
    public static func renamedNoteName(
        current: String, startedAt: Date, title: String, previousTitle: String = defaultTitle, timeZone: TimeZone = .current
    ) -> String? {
        let previous = noteName(startedAt: startedAt, title: previousTitle, timeZone: timeZone)
        guard current == previous || isSuffixed(current, of: previous) else { return nil }
        return noteName(startedAt: startedAt, title: title, timeZone: timeZone)
    }

    private static func isSuffixed(_ name: String, of base: String) -> Bool {
        guard name.hasPrefix(base + " ("), name.hasSuffix(")") else { return false }
        let number = name.dropFirst(base.count + 2).dropLast()
        return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// `name` if it is free, otherwise `name (2)`, `name (3)`… The comparison ignores case,
    /// like the Mac file system.
    public static func available(_ name: String, taken: Set<String>) -> String {
        let taken = Set(taken.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var suffix = 2
        while taken.contains("\(name) (\(suffix))".lowercased()) {
            suffix += 1
        }
        return "\(name) (\(suffix))"
    }

    /// The folder of the Meetings recorded with Takku, inside the notes folder.
    public static let meetingsFolder = "Meetings"
    /// Folders Takku writes in next to the notes: never a folder for notes, at any level.
    public static let reservedFolders = ["Transcripts", "Screenshots", "_Templates"]

    /// A folder for imported notes inside the notes folder (`takku import --folder`, `folder:` in a
    /// Template), as `YouTube` or `Courses/2026`, or why it is not one: relative, no `.` or `..`, no
    /// hidden names or characters a note name cannot have, no folder named like Takku's own
    /// (`Transcripts`, `Screenshots`, `_Templates`). `Meetings` is the folder of the recorded
    /// Meetings, also allowed. Slashes at the ends and doubled ones are ignored.
    public static func noteFolder(_ text: String) -> Result<String, InvalidFolder> {
        guard !text.hasPrefix("/"), !text.hasPrefix("~") else { return .failure(.absolute) }
        let components = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !components.isEmpty else { return .failure(.empty) }
        for component in components {
            if component.isEmpty || component == "." || component == ".." || component.hasPrefix(".") {
                return .failure(.invalidName(component))
            }
            if fileName(component) != component { return .failure(.invalidName(component)) }
            if let reserved = reservedFolders.first(where: { $0.caseInsensitiveCompare(component) == .orderedSame }) {
                return .failure(.reserved(reserved))
            }
        }
        // `meetings/x` and `Meetings/x` are the same folder on the Mac: written as Takku's.
        var folder = components
        if folder[0].caseInsensitiveCompare(meetingsFolder) == .orderedSame { folder[0] = meetingsFolder }
        return .success(folder.joined(separator: "/"))
    }

    public enum InvalidFolder: Error, Equatable {
        case empty, absolute
        case invalidName(String)
        case reserved(String)

        public var message: String {
            switch self {
            case .empty: "the folder is empty."
            case .absolute: "the folder is inside the notes folder: give it as YouTube or Courses/2026, not as a full path."
            case .invalidName(let name): "\"\(name)\" cannot be a folder name (no ., .., hidden names or * \" \\ < > : | ? # ^ [ ])."
            case .reserved(let name): "\(name) is a folder Takku writes in itself, not one for notes."
            }
        }
    }

    private static func sanitized(_ title: String) -> String {
        fileName(title) ?? defaultTitle
    }

    /// A user-chosen name made valid as an Obsidian file name, `nil` if nothing is left.
    public static func fileName(_ name: String) -> String? {
        let words = name
            .components(separatedBy: forbidden)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
