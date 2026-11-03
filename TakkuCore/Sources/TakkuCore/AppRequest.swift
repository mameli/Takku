import Foundation

/// What `takku import` and `takku regenerate` ask the running app to do (ADR 0015): a file in the
/// requests folder, answered by the app with a file next to it. The command and the app are the
/// same Takku, so the format is theirs alone; `version` lets an app left running after an update
/// refuse a request it does not know.
public struct AppRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public enum Kind: String, Codable, Sendable {
        case importAudio = "import"
        case regenerate
    }

    /// The Summary Profile asked for; `nil` in the request leaves the default (the menu's for an
    /// import, the Meeting's own for a Regeneration).
    public enum ProfileChoice: Codable, Equatable, Sendable {
        /// No Summary: the note holds only the Transcript link.
        case transcript
        case profile(UUID)
    }

    public var version: Int
    public let id: UUID
    public let kind: Kind
    /// Chosen by the command, so it can print it at once and follow the Meeting's `processing.json`.
    public let meetingID: UUID
    /// The absolute path of the file to import.
    public var file: String?
    /// `nil`: the default, as for the Profile.
    public var template: String?
    public var profile: ProfileChoice?
    /// The note's title at creation, already valid as a file name.
    public var title: String?
    /// The note's folder inside `Meetings/`, already checked (`VaultNaming.noteFolder`).
    public var folder: String?

    public init(
        kind: Kind, meetingID: UUID, file: String? = nil, template: String? = nil, profile: ProfileChoice? = nil,
        title: String? = nil, folder: String? = nil, id: UUID = UUID(), version: Int = currentVersion
    ) {
        self.version = version
        self.id = id
        self.kind = kind
        self.meetingID = meetingID
        self.file = file
        self.template = template
        self.profile = profile
        self.title = title
        self.folder = folder
    }
}

/// The app's answer to a request: `error` is `nil` when it was taken (the import converted and
/// queued, the Regeneration queued), otherwise why not, as the menu would say it.
public struct AppRequestAnswer: Codable, Equatable, Sendable {
    public let error: String?

    public init(error: String?) {
        self.error = error
    }
}

/// The folder of the requests and their answers, `~/Library/Application Support/Takku/Requests/`.
/// Every file is written whole (`.atomic`), so a reader never sees half of one.
public struct AppRequestFolder: Sendable {
    public let url: URL

    static let requestSuffix = ".request.json"
    static let answerSuffix = ".answer.json"

    public init(url: URL) {
        self.url = url
    }

    func requestURL(_ id: UUID) -> URL { url.appending(path: id.uuidString + Self.requestSuffix) }
    func answerURL(_ id: UUID) -> URL { url.appending(path: id.uuidString + Self.answerSuffix) }

    /// The command: writes a request for the app.
    public func send(_ request: AppRequest) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Self.encoder.encode(request).write(to: requestURL(request.id), options: .atomic)
    }

    /// The command: the answer to a request, removed once read; `nil` while there is none.
    public func takeAnswer(to id: UUID) -> AppRequestAnswer? {
        let answerURL = answerURL(id)
        guard let data = try? Data(contentsOf: answerURL) else { return nil }
        try? FileManager.default.removeItem(at: answerURL)
        return (try? JSONDecoder().decode(AppRequestAnswer.self, from: data))
            ?? AppRequestAnswer(error: "Takku's answer is unreadable.")
    }

    /// The command, giving up: a request the app has not read yet is withdrawn.
    public func withdraw(_ id: UUID) {
        try? FileManager.default.removeItem(at: requestURL(id))
    }

    /// The app: the next request, oldest first, removed from the folder so it is handled once. A
    /// file that cannot be read as a request is answered, if its name gives an id, and dropped.
    public func takeNext() -> Result<AppRequest, Unreadable>? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
        )) ?? []
        let requests = files
            .filter { $0.lastPathComponent.hasSuffix(Self.requestSuffix) }
            .map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .sorted { ($0.1, $0.0.lastPathComponent) < ($1.1, $1.0.lastPathComponent) }
        guard let file = requests.first?.0 else { return nil }
        let data = try? Data(contentsOf: file)
        try? FileManager.default.removeItem(at: file)
        let id = UUID(uuidString: String(file.lastPathComponent.dropLast(Self.requestSuffix.count)))
        guard let data, let request = try? JSONDecoder().decode(AppRequest.self, from: data), request.id == id else {
            return .failure(Unreadable(id: id))
        }
        return .success(request)
    }

    public struct Unreadable: Error, Equatable {
        public let id: UUID?
    }

    /// The app: answers a request.
    public func answer(_ id: UUID, _ answer: AppRequestAnswer) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Self.encoder.encode(answer).write(to: answerURL(id), options: .atomic)
    }

    /// The app, at launch: answers nobody read (the command was stopped) older than a day.
    public func removeStaleAnswers(now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        )) ?? []
        for file in files where file.lastPathComponent.hasSuffix(Self.answerSuffix) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(modified) > 24 * 60 * 60 { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
