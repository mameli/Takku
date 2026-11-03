import AppKit
import TakkuCore

/// The notes folder, where Takku writes Meeting notes and Transcripts: any folder, an Obsidian
/// Vault or not. In the code it is still the Vault.
struct Vault {
    let root: URL

    var meetingsFolder: URL { root.appending(path: "Meetings", directoryHint: .isDirectory) }
    var transcriptsFolder: URL { meetingsFolder.appending(path: "Transcripts", directoryHint: .isDirectory) }
    var screenshotsFolder: URL { meetingsFolder.appending(path: "Screenshots", directoryHint: .isDirectory) }

    /// Zed follows a renamed note but misses a write that arrives within about a second of the
    /// rename, before or after it: its tab keeps showing the old content. A write to a note
    /// that was just renamed waits this long (1 second was enough in a test).
    static let settleAfterRename: Duration = .milliseconds(1500)

    static var configured: Vault? {
        AppSettings.vaultPath.map { Vault(root: URL(filePath: $0, directoryHint: .isDirectory)) }
    }

    /// Where the welcome window offers to put the notes, for those with no folder in mind.
    static let suggestedRoot = URL.documentsDirectory.appending(path: "Takku", directoryHint: .isDirectory)

    /// Creates the suggested folder and saves it. The path, or `nil` if it could not be created.
    @MainActor
    static func useSuggested() -> String? {
        do {
            try FileManager.default.createDirectory(at: suggestedRoot, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let path = suggestedRoot.path(percentEncoded: false)
        AppSettings.vaultPath = path
        return path
    }

    /// Asks for the notes folder (Settings, welcome window) and saves it. The chosen path, or
    /// `nil` if the user cancelled.
    @MainActor
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Use this folder")
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
    ///
    /// `folder` (`takku import --folder`, already checked by `VaultNaming.noteFolder`) puts it in a
    /// folder inside `Meetings/`, made if missing; `title` (`--title`) names it instead of the event.
    func createMeetingNote(
        takkuID: UUID, startedAt: Date, event: CalendarEvent? = nil, isImport: Bool = false,
        folder: String? = nil, title: String? = nil
    ) throws -> URL {
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else {
            throw VaultError.unreachable(root.path(percentEncoded: false))
        }
        let noteFolder = noteFolder(folder)
        try FileManager.default.createDirectory(at: noteFolder, withIntermediateDirectories: true)
        // Also the names in Meetings/ itself: `[[…]]` links find a note by its name alone.
        let name = VaultNaming.available(
            VaultNaming.noteName(startedAt: startedAt, title: title ?? event?.title ?? VaultNaming.defaultTitle),
            taken: Self.noteNames(in: noteFolder).union(Self.noteNames(in: meetingsFolder))
        )
        let url = noteFolder.appending(path: name + ".md")
        let note = MeetingNote.initial(takkuID: takkuID, startedAt: startedAt, participants: event?.participants ?? [], isImport: isImport)
        try note.content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Names the Meeting note after another calendar event the user picked while recording, or
    /// after none: a note still named after the previous event (or provisional) takes the new
    /// event's name (the provisional one without an event, so Processing gives it a generated
    /// title). A note renamed or moved by the user keeps its name. Returns where the note is now.
    /// The caller writes the event's participants a moment later (see `settleAfterRename`).
    func renameForEvent(_ noteURL: URL, startedAt: Date, from previous: CalendarEvent?, to event: CalendarEvent?) throws -> URL {
        guard isInMeetingsFolder(noteURL), let newName = VaultNaming.renamedNoteName(
            current: noteURL.deletingPathExtension().lastPathComponent, startedAt: startedAt,
            title: event?.title ?? VaultNaming.defaultTitle, previousTitle: previous?.title ?? VaultNaming.defaultTitle
        ) else { return noteURL }
        return try rename(noteURL, to: newName)
    }

    /// The Meeting note: at the known path or, if the user renamed or moved it, by looking
    /// for its `takku_id` in the Meetings folder (Transcripts excluded). Sync copies with the
    /// same ID are an error unless the expected path identifies one; the first one is never chosen.
    func findMeetingNote(takkuID: UUID, expected: URL?) throws -> URL? {
        // Only inside this Vault: a note left in another Vault (or a test's copy of a real Meeting) is not touched.
        if let expected, contains(expected), Self.takkuID(of: expected) == takkuID { return expected }
        let matches = files(in: meetingsFolder, excluding: transcriptsFolder).filter { Self.takkuID(of: $0) == takkuID }
        return try uniqueMatch(matches, takkuID: takkuID)
    }

    /// Every Meeting note by `takku_id`, duplicates included, in one pass.
    func meetingNotesByTakkuID() -> [UUID: [URL]] {
        Self.byTakkuID(files(in: meetingsFolder, excluding: transcriptsFolder))
    }

    /// Every Transcript by `takku_id`, duplicates included, in one pass.
    func transcriptsByTakkuID() -> [UUID: [URL]] {
        Self.byTakkuID(files(in: transcriptsFolder))
    }

    /// The Transcript file of a Meeting. If Sync created several files with the same ID, the
    /// Meeting note's own Transcript link identifies the right one; otherwise this is a conflict.
    func findTranscript(takkuID: UUID, expectedNote: URL?) throws -> URL? {
        let matches = files(in: transcriptsFolder).filter { Self.takkuID(of: $0) == takkuID }
        if matches.count > 1,
           let noteURL = try findMeetingNote(takkuID: takkuID, expected: expectedNote),
           let linkedName = try? meetingNote(at: noteURL).transcriptName {
            let linked = matches.filter { $0.deletingPathExtension().lastPathComponent == linkedName }
            if linked.count == 1 { return linked[0] }
        }
        return try uniqueMatch(matches, takkuID: takkuID)
    }

    /// Writes the Transcript in the Vault. If a file of the same Meeting already exists it is
    /// overwritten, so a new Processing does not create duplicates.
    func writeTranscript(
        _ transcript: Transcript, takkuID: UUID, meetingNote: URL?, meetingNoteName: String, language: String?
    ) throws -> URL {
        try FileManager.default.createDirectory(at: transcriptsFolder, withIntermediateDirectories: true)
        let url = try findTranscript(takkuID: takkuID, expectedNote: meetingNote) ?? {
            let name = VaultNaming.available("\(meetingNoteName) (transcript)", taken: Self.noteNames(in: transcriptsFolder))
            return transcriptsFolder.appending(path: name + ".md")
        }()
        let content = transcript.vaultFile(takkuID: takkuID, meetingNoteName: meetingNoteName, language: language)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Copies the Screenshots of a Recording folder into the Vault, only those not already there:
    /// a Retry overwrites nothing. Takku never deletes them from the Vault.
    func copyScreenshots(_ screenshots: [Screenshot], fromRecordingFolder folder: URL) throws {
        guard !screenshots.isEmpty else { return }
        try FileManager.default.createDirectory(at: screenshotsFolder, withIntermediateDirectories: true)
        for screenshot in screenshots {
            let destination = screenshotsFolder.appending(path: screenshot.embed)
            guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else { continue }
            try FileManager.default.copyItem(
                at: folder.appending(path: Screenshot.folderName).appending(path: screenshot.embed), to: destination
            )
        }
    }

    /// The file is inside this Vault, symlinks resolved.
    func contains(_ url: URL) -> Bool {
        let normalized = normalizer()
        return normalized(url).starts(with: normalized(root))
    }

    /// The note is still in the Meetings folder, where Takku created it (it was not moved).
    func isInMeetingsFolder(_ noteURL: URL) -> Bool {
        isInNoteFolder(noteURL, folder: nil)
    }

    /// The note is still in the folder Takku created it in: `Meetings/` or, for `takku import
    /// --folder`, that folder inside it.
    func isInNoteFolder(_ noteURL: URL, folder: String?) -> Bool {
        let normalized = normalizer()
        return normalized(noteURL.deletingLastPathComponent()) == normalized(noteFolder(folder))
    }

    private func noteFolder(_ folder: String?) -> URL {
        folder.map { meetingsFolder.appending(path: $0, directoryHint: .isDirectory) } ?? meetingsFolder
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

    /// Opens a note in the Editor. Any note Takku opens replaces a pending wait to show a renamed note.
    @MainActor
    static func openInEditor(_ url: URL) {
        RenamedNoteFollower.cancel()
        open(url, in: .current)
    }

    static func showInObsidian(_ url: URL) {
        var components = URLComponents(string: "obsidian://open")!
        components.queryItems = [URLQueryItem(name: "path", value: url.path(percentEncoded: false))]
        NSWorkspace.shared.open(components.url!)
    }

    /// The *Show all* item of Recent meetings: Obsidian's search lists the Meeting notes; another
    /// Editor gets the whole Vault if it opens folders (Zed does), otherwise the Finder shows it.
    enum ShowAll {
        case obsidianSearch
        case vault(in: URL)
        case finder

        init(_ editor: Editor) {
            switch editor {
            case .obsidian:
                self = .obsidianSearch
            case .app(let bundleID):
                if let app = Editor.appURL(bundleID), TextEditors.opensFolders(app) {
                    self = .vault(in: app)
                } else {
                    self = .finder
                }
            case .systemDefault:
                self = .finder
            }
        }

        var title: String {
            switch self {
            case .obsidianSearch: String(localized: "Show all in Obsidian…")
            case .vault(let app): String(localized: "Open the notes folder in \(TextEditors.name(of: app))…")
            case .finder: String(localized: "Show the notes folder in Finder…")
            }
        }
    }

    func show(_ showAll: ShowAll) {
        switch showAll {
        case .obsidianSearch:
            var components = URLComponents(string: "obsidian://search")!
            components.queryItems = [
                // Obsidian knows a Vault by its folder name.
                URLQueryItem(name: "vault", value: root.lastPathComponent),
                URLQueryItem(name: "query", value: "[takku_id] -path:\"Meetings/Transcripts\""),
            ]
            NSWorkspace.shared.open(components.url!)
        case .vault(let app):
            TextEditors.open(root, with: app)
        case .finder:
            NSWorkspace.shared.activateFileViewerSelecting([root])
        }
    }

    /// Obsidian finds a file only once it has noticed it on disk: opened right after being
    /// created, it sometimes answers "file not found". Other Editors open it at once.
    @MainActor
    static func openNewFileInEditor(_ url: URL) {
        RenamedNoteFollower.cancel()
        let editor = Editor.current
        guard editor == .obsidian else { return open(url, in: editor) }
        Task {
            try? await Task.sleep(for: .seconds(1))
            showInObsidian(url)
        }
    }

    private static func open(_ url: URL, in editor: Editor) {
        switch editor {
        case .obsidian:
            showInObsidian(url)
        case .app(let bundleID):
            if let app = Editor.appURL(bundleID) {
                TextEditors.open(url, with: app)
            } else {
                NSWorkspace.shared.open(url)
            }
        case .systemDefault:
            NSWorkspace.shared.open(url)
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

    private static func takkuID(of url: URL) -> UUID? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap { MeetingNote(content: $0).takkuID }
    }

    private static func byTakkuID(_ urls: [URL]) -> [UUID: [URL]] {
        var byID: [UUID: [URL]] = [:]
        for url in urls {
            if let takkuID = takkuID(of: url) { byID[takkuID, default: []].append(url) }
        }
        return byID
    }

    func uniqueMatch(_ matches: [URL], takkuID: UUID) throws -> URL? {
        guard matches.count > 1 else { return matches.first }
        let rootPath = root.path(percentEncoded: false)
        let paths = matches.map { url in
            let path = url.path(percentEncoded: false)
            return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
        }.sorted()
        throw VaultError.duplicateTakkuID(takkuID, paths)
    }

    private func files(in folder: URL, excluding excluded: URL? = nil) -> [URL] {
        let normalized = normalizer()
        let excludedComponents = excluded.map(normalized)
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        var matches: [URL] = []
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            if let excludedComponents, normalized(url).starts(with: excludedComponents) { continue }
            matches.append(url)
        }
        return matches
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
    case duplicateTakkuID(UUID, [String])

    var errorDescription: String? {
        switch self {
        case .unreachable(let path): String(localized: "Notes folder not reachable: \(path).")
        case .busy(let file): String(localized: "\(file) keeps changing while Takku tries to update it.")
        case .invalidName(let name): String(localized: "\"\(name)\" is not a valid file name.")
        case .duplicateTakkuID(let takkuID, let paths):
            String(localized: "Duplicate takku_id \(takkuID.uuidString). Takku cannot safely choose between: \(paths.joined(separator: ", ")). Fix the duplicate notes or Transcript links in the notes folder.")
        }
    }
}
