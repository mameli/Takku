import AppKit
import TakkuCore

/// The Obsidian Vault where Takku writes Meeting notes and Transcripts.
struct Vault {
    let root: URL

    var meetingsFolder: URL { root.appending(path: "Meetings", directoryHint: .isDirectory) }
    var transcriptsFolder: URL { meetingsFolder.appending(path: "Transcripts", directoryHint: .isDirectory) }

    static var configured: Vault? {
        AppSettings.vaultPath.map { Vault(root: URL(filePath: $0, directoryHint: .isDirectory)) }
    }

    /// Asks for the Vault folder (Settings, welcome window) and saves it. The chosen path, or
    /// `nil` if the user cancelled.
    @MainActor
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Use this Vault")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let path = url.path(percentEncoded: false)
        AppSettings.vaultPath = path
        return path
    }

    // MARK: - Meeting notes and Transcripts

    /// Creates the Meeting note named after the calendar event, if there is one, otherwise with the
    /// provisional title (replaced by the generated one at the end of Processing). Never creates the
    /// Vault folder: if it is missing (volume not mounted) it fails, and the note is created at the
    /// end of Processing.
    func createMeetingNote(takkuID: UUID, startedAt: Date, event: CalendarEvent? = nil) throws -> URL {
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else {
            throw VaultError.unreachable(root.path(percentEncoded: false))
        }
        try FileManager.default.createDirectory(at: meetingsFolder, withIntermediateDirectories: true)
        let name = VaultNaming.available(
            VaultNaming.noteName(startedAt: startedAt, title: event?.title ?? VaultNaming.defaultTitle),
            taken: Self.noteNames(in: meetingsFolder)
        )
        let url = meetingsFolder.appending(path: name + ".md")
        let note = MeetingNote.initial(takkuID: takkuID, startedAt: startedAt, participants: event?.participants ?? [])
        try note.content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The Meeting note: at the known path or, if the user renamed or moved it, by looking
    /// for its `takku_id` in the Meetings folder (Transcripts excluded).
    func findMeetingNote(takkuID: UUID, expected: URL?) -> URL? {
        // Only inside this Vault: a note left in another Vault (or a test's copy of a real Meeting) is not touched.
        if let expected, contains(expected), Self.belongs(expected, to: takkuID) { return expected }
        return firstFile(in: meetingsFolder, excluding: transcriptsFolder) { Self.belongs($0, to: takkuID) }
    }

    /// The Meeting notes in the Meetings folder (Transcripts excluded) by `takku_id`, in one pass:
    /// for looking up many Meetings at once.
    func meetingNotesByTakkuID() -> [UUID: URL] {
        var notes: [UUID: URL] = [:]
        _ = firstFile(in: meetingsFolder, excluding: transcriptsFolder) { url in
            if let takkuID = (try? String(contentsOf: url, encoding: .utf8)).flatMap({ MeetingNote(content: $0).takkuID }),
               notes[takkuID] == nil {
                notes[takkuID] = url
            }
            return false
        }
        return notes
    }

    /// The Transcript file of a Meeting, found by its `takku_id`.
    func findTranscript(takkuID: UUID) -> URL? {
        firstFile(in: transcriptsFolder) { Self.belongs($0, to: takkuID) }
    }

    /// Writes the Transcript in the Vault. If a file of the same Meeting already exists it is
    /// overwritten, so a new Processing does not create duplicates.
    func writeTranscript(_ transcript: Transcript, takkuID: UUID, meetingNoteName: String, language: String?) throws -> URL {
        try FileManager.default.createDirectory(at: transcriptsFolder, withIntermediateDirectories: true)
        let url = findTranscript(takkuID: takkuID) ?? {
            let name = VaultNaming.available("\(meetingNoteName) (transcript)", taken: Self.noteNames(in: transcriptsFolder))
            return transcriptsFolder.appending(path: name + ".md")
        }()
        let content = transcript.vaultFile(takkuID: takkuID, meetingNoteName: meetingNoteName, language: language)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The file is inside this Vault, symlinks resolved.
    func contains(_ url: URL) -> Bool {
        let normalized = normalizer()
        return normalized(url).starts(with: normalized(root))
    }

    /// The note is still in the Meetings folder, where Takku created it (it was not moved).
    func isInMeetingsFolder(_ noteURL: URL) -> Bool {
        let normalized = normalizer()
        return normalized(noteURL.deletingLastPathComponent()) == normalized(meetingsFolder)
    }

    /// Path components with symlinks resolved, lowercased unless the Vault's volume tells names apart
    /// by case (APFS and HFS+ do not by default; unknown, volume not mounted, counts as not). It reads
    /// the volume once: keep it for many paths.
    private func normalizer() -> (URL) -> [String] {
        let caseSensitive = (try? root.resolvingSymlinksInPath().resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
        return { url in
            let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            return caseSensitive ? components : components.map { $0.lowercased() }
        }
    }

    /// Renames the note (with a " (2)" suffix if the name is taken) and returns the new path.
    func rename(_ noteURL: URL, to name: String) throws -> URL {
        let folder = noteURL.deletingLastPathComponent()
        let current = noteURL.deletingPathExtension().lastPathComponent
        let available = VaultNaming.available(name, taken: Self.noteNames(in: folder).subtracting([current]))
        let destination = folder.appending(path: available + ".md")
        guard destination != noteURL else { return noteURL }
        try FileManager.default.moveItem(at: noteURL, to: destination)
        return destination
    }

    func meetingNote(at url: URL) throws -> MeetingNote {
        MeetingNote(content: try String(contentsOf: url, encoding: .utf8))
    }

    /// Edits an existing note. If Obsidian saves it between the read and the write, it is read
    /// again and the change reapplied, so what the user just typed is not lost.
    /// The write happens on the file itself (not replacing it): symlinks and creation date survive.
    func update(_ noteURL: URL, _ change: (inout MeetingNote) -> Void) throws {
        for _ in 0..<3 {
            let before = try Self.modificationDate(noteURL)
            var note = MeetingNote(content: try String(contentsOf: noteURL, encoding: .utf8))
            change(&note)
            guard try Self.modificationDate(noteURL) == before else { continue }
            try note.content.write(to: noteURL, atomically: false, encoding: .utf8)
            return
        }
        throw VaultError.busy(noteURL.lastPathComponent)
    }

    /// Any note Takku opens replaces a pending wait to show a renamed note.
    @MainActor
    static func openInObsidian(_ url: URL) {
        RenamedNoteFollower.cancel()
        showInObsidian(url)
    }

    static func showInObsidian(_ url: URL) {
        var components = URLComponents(string: "obsidian://open")!
        components.queryItems = [URLQueryItem(name: "path", value: url.path(percentEncoded: false))]
        NSWorkspace.shared.open(components.url!)
    }

    /// Obsidian's search on this Vault, listing the Meeting notes (Transcripts excluded).
    func showMeetingsInObsidian() {
        var components = URLComponents(string: "obsidian://search")!
        components.queryItems = [
            // Obsidian knows a Vault by its folder name.
            URLQueryItem(name: "vault", value: root.lastPathComponent),
            URLQueryItem(name: "query", value: "[takku_id] -path:\"Meetings/Transcripts\""),
        ]
        NSWorkspace.shared.open(components.url!)
    }

    /// Obsidian finds a file only once it has noticed it on disk: opened right after being
    /// created, it sometimes answers "file not found".
    @MainActor
    static func openNewFileInObsidian(_ url: URL) {
        RenamedNoteFollower.cancel()
        Task {
            try? await Task.sleep(for: .seconds(1))
            showInObsidian(url)
        }
    }

    /// Whether Obsidian shows `note` in its active tab, read from `.obsidian/workspace.json`;
    /// `nil` when that file cannot be read (another configuration folder, Vault never opened).
    func isShownInObsidian(_ note: URL) -> Bool? {
        let workspaceURL = root.appending(path: ".obsidian/workspace.json")
        guard let data = try? Data(contentsOf: workspaceURL) else { return nil }
        guard let path = ObsidianWorkspace.activeFile(in: data) else { return false }
        return root.appending(path: path).standardizedFileURL.path == note.standardizedFileURL.path
    }

    // MARK: - Private

    private static func belongs(_ url: URL, to takkuID: UUID) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8)).map { MeetingNote(content: $0).takkuID == takkuID } ?? false
    }

    private func firstFile(in folder: URL, excluding excluded: URL? = nil, where matches: (URL) -> Bool) -> URL? {
        let normalized = normalizer()
        let excludedComponents = excluded.map(normalized)
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            if let excludedComponents, normalized(url).starts(with: excludedComponents) { continue }
            if matches(url) { return url }
        }
        return nil
    }

    private static func noteNames(in folder: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { $0.pathExtension == "md" }.map { $0.deletingPathExtension().lastPathComponent })
    }

    private static func modificationDate(_ url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date
    }
}

enum VaultError: LocalizedError {
    case unreachable(String)
    case busy(String)
    case invalidName(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let path): String(localized: "Vault not reachable: \(path).")
        case .busy(let file): String(localized: "\(file) keeps changing while Takku tries to update it.")
        case .invalidName(let name): String(localized: "\"\(name)\" is not a valid file name.")
        }
    }
}
