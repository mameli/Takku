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

    /// Folders of `Meetings/` that are Takku's own, never a folder for notes.
    public static let reservedFolders = ["Transcripts", "Screenshots", "_Templates"]

    /// A folder for a note inside `Meetings/` (`takku import --folder`), as `YouTube/Corsi`, or why
    /// it is not one: relative, no `.` or `..`, no character a note name cannot have, not one of
    /// Takku's own folders. Slashes at the ends and doubled ones are ignored.
    public static func noteFolder(_ text: String) -> Result<String, InvalidFolder> {
        guard !text.hasPrefix("/"), !text.hasPrefix("~") else { return .failure(.absolute) }
        let components = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !components.isEmpty else { return .failure(.empty) }
        for component in components {
            if component.isEmpty || component == "." || component == ".." || component.hasPrefix(".") {
                return .failure(.invalidName(component))
            }
            if fileName(component) != component { return .failure(.invalidName(component)) }
        }
        if reservedFolders.contains(where: { $0.caseInsensitiveCompare(components[0]) == .orderedSame }) {
            return .failure(.reserved(components[0]))
        }
        return .success(components.joined(separator: "/"))
    }

    public enum InvalidFolder: Error, Equatable {
        case empty, absolute
        case invalidName(String)
        case reserved(String)

        public var message: String {
            switch self {
            case .empty: "the folder is empty."
            case .absolute: "the folder is inside Meetings/: give it as YouTube or Courses/2026, not as a full path."
            case .invalidName(let name): "\"\(name)\" cannot be a folder name (no ., .., hidden names or * \" \\ < > : | ? # ^ [ ])."
            case .reserved(let name): "\(name) is Takku's own folder."
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
