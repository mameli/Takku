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
    public var importWarnings: [String]?
    /// The status before a Retry or a Regeneration, while it is queued or running: stopping it, or
    /// a restart in the middle of a Regeneration, gives the Meeting back as it was.
    public var statusBeforeRetry: Status?
    /// The folder of the notes folder where Takku creates the note of an import (`takku import
    /// --folder`, or the Template's `folder:`), `nil` for `Meetings/`. A note still there is where
    /// Takku put it, and gets its title.
    public var noteFolder: String?
    /// The title given at the import (`--title`), for a note created only at the end of Processing.
    public var noteTitle: String?
    /// The Personal notes given at the import (`--notes`), for a note created only at the end of Processing.
    public var notes: String?
    /// The languages of an import (`--language`), used instead of the Meeting languages of Settings,
    /// also when it is reprocessed. `nil`: those of Settings at the time.
    public var languages: [String]?

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
        reprocessing: Reprocessing? = nil, importedAt: Date? = nil, importWarnings: [String]? = nil,
        noteFolder: String? = nil, noteTitle: String? = nil, notes: String? = nil, languages: [String]? = nil
    ) {
        self.notes = notes
        self.languages = languages
        self.noteFolder = noteFolder
        self.noteTitle = noteTitle
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

    /// After a restart: Meetings queued, in progress or interrupted while recording resume.
    /// An interrupted Regeneration is not redone as full Processing (the audio may be gone):
    /// the Meeting simply goes back to what it was before (completed, for a record written
    /// before that was saved).
    public static func afterRestart(_ records: [ProcessingRecord]) -> RestartPlan {
        let toProcess = records
            .filter { [.recording, .queued, .processing].contains($0.status) }
            .sorted { $0.startedAt < $1.startedAt }
        let toSave = records
            .filter { $0.status == .regenerating }
            .map { record in
                var record = record
                record.status = record.statusBeforeRetry ?? .completed
                record.statusBeforeRetry = nil
                return record
            }
        return RestartPlan(toProcess: toProcess, toSave: toSave)
    }

    /// Queues a concluded Meeting again to redo the whole Processing.
    public mutating func queueForRetry() throws {
        guard status.canRetry else { throw InvalidTransition(from: status) }
        statusBeforeRetry = status
        status = .queued
    }

    public mutating func beginRegeneration() throws {
        guard status.canRetry else { throw InvalidTransition(from: status) }
        statusBeforeRetry = status
        status = .regenerating
    }

    /// Stops a queued or running Processing (*Stop processing* in the menu). A Retry or a
    /// Regeneration gives the Meeting back as it was before it; a Meeting never processed fails with
    /// `reason`, so it can be retried and is not resumed after a restart. A Meeting being recorded
    /// is stopped with the recording, not here.
    public mutating func stop(reason: String) throws {
        guard [.queued, .processing, .regenerating].contains(status) else { throw InvalidTransition(from: status) }
        status = statusBeforeRetry ?? .failed(reason: reason)
        statusBeforeRetry = nil
        reprocessing = nil
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
