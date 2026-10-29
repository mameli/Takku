import Foundation

/// The Processing state of a Meeting, saved in the Recording folder (`processing.json`)
/// so it survives an app restart or crash.
public struct ProcessingRecord: Codable, Equatable, Sendable {
    public enum Status: Codable, Equatable, Sendable {
        /// The Meeting is being recorded (if the app restarts in this state, it crashed).
        case recording
        case queued
        case processing
        /// New Summary from the Transcript in the Vault; does not involve the audio.
        case regenerating
        case completed
        case failed(reason: String)

        /// Not concluded yet: its audio is not deleted and Retry and Regenerate are not offered.
        public var isPending: Bool {
            switch self {
            case .recording, .queued, .processing, .regenerating: true
            case .completed, .failed: false
            }
        }

        /// Retry and Regenerate only make sense for a concluded Meeting.
        public var canRetry: Bool { !isPending }
    }

    public struct InvalidTransition: Error, Equatable {
        public let from: Status
    }

    /// What to do after the app restarts.
    public struct RestartPlan: Sendable {
        /// Processing to (re)do, oldest Meeting first.
        public let toProcess: [ProcessingRecord]
        /// States to fix on disk without processing again.
        public let toSave: [ProcessingRecord]
    }

    public let takkuID: UUID
    public let startedAt: Date
    public var status: Status
    public var templateName: String
    /// Fixed when the Meeting starts (ADR 0001).
    public var summaryProfile: ProviderProfile?
    /// Path of the Meeting note, if it was created.
    public var noteURL: URL?
    /// Set only while an explicit Reprocess Recording is queued or running. Kept here so a restart
    /// cannot turn one from scratch back into a cache hit, and so its outcome can say how the
    /// Transcript was rebuilt.
    public var reprocessing: Reprocessing?
    /// When the source file was imported, not when the Meeting was originally recorded.
    public var importedAt: Date?
    /// Source audio skipped during import: persisted so Processing can report it after a restart.
    public var importWarnings: [String]

    /// How Reprocess Recording rebuilds the Transcript from the audio.
    public enum Reprocessing: String, Codable, Sendable {
        /// Segments and Speaker turns whose cache is still valid are reused: the Transcript is
        /// rebuilt with the current Vocabulary, echo removal and Speaker names, and only Segments
        /// cached by another model or language are transcribed again.
        case reusingCache
        /// Every Segment is transcribed and the Others Track diarized again, ignoring the caches.
        case fromScratch
    }

    public var ignoresTranscriptionCache: Bool { reprocessing == .fromScratch }

    /// Recency in the menu: an old memo imported now is a recent Meeting.
    public var recentAt: Date { importedAt ?? startedAt }

    public init(
        takkuID: UUID, startedAt: Date, status: Status,
        templateName: String, summaryProfile: ProviderProfile?, noteURL: URL?,
        reprocessing: Reprocessing? = nil, importedAt: Date? = nil, importWarnings: [String] = []
    ) {
        self.takkuID = takkuID
        self.startedAt = startedAt
        self.status = status
        self.templateName = templateName
        self.summaryProfile = summaryProfile
        self.noteURL = noteURL
        self.reprocessing = reprocessing
        self.importedAt = importedAt
        self.importWarnings = importWarnings
    }

    private enum CodingKeys: String, CodingKey {
        case takkuID, startedAt, status, templateName, summaryProfile, noteURL, reprocessing, importedAt, importWarnings
    }

    /// Records written before these fields existed keep the normal cached Processing behavior.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        takkuID = try values.decode(UUID.self, forKey: .takkuID)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        status = try values.decode(Status.self, forKey: .status)
        templateName = try values.decode(String.self, forKey: .templateName)
        summaryProfile = try values.decodeIfPresent(ProviderProfile.self, forKey: .summaryProfile)
        noteURL = try values.decodeIfPresent(URL.self, forKey: .noteURL)
        reprocessing = try values.decodeIfPresent(Reprocessing.self, forKey: .reprocessing)
        importedAt = try values.decodeIfPresent(Date.self, forKey: .importedAt)
        importWarnings = try values.decodeIfPresent([String].self, forKey: .importWarnings) ?? []
    }

    /// After a restart: Meetings queued, in progress or interrupted while recording resume.
    /// An interrupted Regeneration is not redone as full Processing (the audio may be gone):
    /// the Meeting simply goes back to completed.
    public static func afterRestart(_ records: [ProcessingRecord]) -> RestartPlan {
        let toProcess = records
            .filter { [.recording, .queued, .processing].contains($0.status) }
            .sorted { $0.startedAt < $1.startedAt }
        let toSave = records
            .filter { $0.status == .regenerating }
            .map { record in
                var record = record
                record.status = .completed
                return record
            }
        return RestartPlan(toProcess: toProcess, toSave: toSave)
    }

    /// Queues a concluded Meeting again to redo the whole Processing.
    public mutating func queueForRetry() throws {
        guard status.canRetry else { throw InvalidTransition(from: status) }
        status = .queued
    }

    public mutating func beginRegeneration() throws {
        guard status.canRetry else { throw InvalidTransition(from: status) }
        status = .regenerating
    }

    /// The Template a Retry uses. A failed Meeting keeps its own: the Retry redoes the Summary that
    /// did not come out, while the menu has gone back to the default Template at the stop.
    /// A completed one takes the Template chosen in the menu, since it is retried to change it.
    public func retryTemplate(chosen: String) -> String {
        if case .failed = status { templateName } else { chosen }
    }

    public static let fileName = "processing.json"

    public static func load(fromFolder folder: URL) throws -> ProcessingRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProcessingRecord.self, from: Data(contentsOf: folder.appending(path: fileName)))
    }

    public func save(inFolder directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: directory.appending(path: Self.fileName), options: .atomic)
    }
}
