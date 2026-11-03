import Foundation

/// What the terminal commands and the MCP server read of the app without starting it: the
/// Templates, the Summary Profiles and the Processing state of each Meeting (`processing.json`).
/// Read only. The app target fills it from its Settings and folders.
public struct TakkuState: Sendable {
    /// Template names, as in `~/.takku/templates/` without `.md`.
    public var templates: [String]
    public var defaultTemplate: String
    public var profiles: [ProviderProfile]
    /// The Profile chosen in the menu; `nil` is *Transcript*.
    public var activeProfileID: UUID?
    /// `~/Library/Application Support/Takku/Recordings/`, one folder per Meeting.
    public var recordingsFolder: URL

    public init(
        templates: [String], defaultTemplate: String, profiles: [ProviderProfile], activeProfileID: UUID?,
        recordingsFolder: URL
    ) {
        self.templates = templates
        self.defaultTemplate = defaultTemplate
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.recordingsFolder = recordingsFolder
    }

    // MARK: - Templates and Profiles

    /// The Template named `name`, ignoring case, as its file is named.
    public func template(named name: String) -> String? {
        templates.first { $0 == name } ?? templates.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// `--profile`: `transcript`, a Profile's id, or its name ignoring case; otherwise why not.
    public func profileChoice(_ text: String) -> Result<AppRequest.ProfileChoice, ChoiceError> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.caseInsensitiveCompare("transcript") == .orderedSame { return .success(.transcript) }
        if let id = UUID(uuidString: trimmed), profiles.contains(where: { $0.id == id }) { return .success(.profile(id)) }
        let named = profiles.filter { $0.displayName.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(trimmed) == .orderedSame }
        switch named.count {
        case 1: return .success(.profile(named[0].id))
        case 0: return .failure(ChoiceError(message: "no Summary Profile named \"\(trimmed)\": see takku profiles."))
        default: return .failure(ChoiceError(message: "\(named.count) Summary Profiles are named \"\(trimmed)\": pass the id from takku profiles."))
        }
    }

    public struct ChoiceError: Error, Equatable {
        public let message: String
    }

    var templateFields: [[String: Any]] {
        templates.map { ["name": $0, "default": $0 == defaultTemplate] }
    }

    var profileFields: [[String: Any]] {
        profiles.map { profile in
            ["id": profile.id.uuidString, "name": profile.displayName, "model": profile.model,
             "on_this_mac": profile.runsOnThisMac, "active": profile.id == activeProfileID]
        }
    }

    // MARK: - Processing

    /// The Processing state of the Meeting, `nil` when it has no Recording folder.
    public func record(_ id: UUID) -> ProcessingRecord? {
        try? ProcessingRecord.load(fromFolder: recordingsFolder.appending(path: id.uuidString, directoryHint: .isDirectory))
    }

    /// Every Meeting with a Recording folder, the most recent first.
    public func records() -> [ProcessingRecord] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: recordingsFolder, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { try? ProcessingRecord.load(fromFolder: $0) }.sorted { $0.recentAt > $1.recentAt }
    }

    /// The Meetings not concluded yet, the oldest first, as they go through the queue.
    public func pendingRecords() -> [ProcessingRecord] {
        records().filter(\.status.isPending).sorted { $0.recentAt < $1.recentAt }
    }

    func statusFields(_ record: ProcessingRecord) -> [String: Any] {
        var fields: [String: Any] = [
            "id": record.takkuID.uuidString, "status": Self.statusName(record.status),
            "started_at": ISO8601DateFormatter().string(from: record.startedAt), "template": record.templateName,
        ]
        if case .failed(let reason) = record.status { fields["error"] = reason }
        fields["note"] = record.noteURL?.path(percentEncoded: false)
        fields["title"] = Self.title(record)
        fields["profile"] = record.summaryProfile?.displayName
        fields["imported_at"] = record.importedAt.map { ISO8601DateFormatter().string(from: $0) }
        return fields
    }

    static func statusName(_ status: ProcessingRecord.Status) -> String {
        switch status {
        case .recording: "recording"
        case .queued: "queued"
        case .processing: "processing"
        case .regenerating: "regenerating"
        case .completed: "completed"
        case .failed: "failed"
        }
    }

    /// The note's title, or the start when there is no note yet.
    static func title(_ record: ProcessingRecord) -> String {
        record.noteURL.map { MeetingLibrary.title(fromNoteName: $0.deletingPathExtension().lastPathComponent) }
            ?? DateFormatter.posix("yyyy-MM-dd HH:mm", timeZone: .current).string(from: record.startedAt)
    }

    /// "queued · Lezione 3 · Lecture" and the id under it; a failure's reason below.
    static func line(_ record: ProcessingRecord) -> String {
        var text = [statusName(record.status), title(record), record.templateName].joined(separator: " · ")
            + "\n    \(record.takkuID.uuidString)"
        if case .failed(let reason) = record.status { text += "\n    \(reason)" }
        return text
    }
}
