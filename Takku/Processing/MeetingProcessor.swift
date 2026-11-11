import AppKit
import Foundation
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "processing")

/// Meeting Processing: one at a time, in arrival order, with the state saved in the Recording
/// folder (`processing.json`) so it resumes after a restart or a crash. Also handles Retry and
/// starts the cleanup of expired audio (`RecordingStorage`).
@MainActor
@Observable
final class MeetingProcessor {
    enum RetryMode {
        /// Full Processing while the audio exists, Regeneration otherwise (automated tests).
        case automatic
        /// Always from the current Transcript in the Vault, even when the audio exists.
        case summary
        /// Rebuild the Transcript from the Recording, then write the Summary. `fromScratch` ignores
        /// the transcription and Speaker caches; otherwise the valid ones are reused.
        case recording(fromScratch: Bool)
    }

    enum Phase: Equatable {
        case transcribing(part: Int, total: Int)
        case preparingSpeakers
        case identifyingSpeakers
        case writingSummary(part: Int, total: Int)
        case mergingSummary
        case writingNote
        /// *Stop processing* was chosen: the current step is ending.
        case stopping

        var label: String {
            switch self {
            case .transcribing(let part, let total):
                part > 0 && total > 0
                    ? String(localized: "Transcribing · part \(part)/\(total)")
                    : String(localized: "Transcribing…")
            case .preparingSpeakers:
                String(localized: "Preparing speaker recognition…")
            case .identifyingSpeakers:
                String(localized: "Identifying speakers…")
            case .writingSummary(let part, let total):
                part > 0 && total > 0
                    ? String(localized: "Writing Summary · part \(part)/\(total)")
                    : String(localized: "Writing Summary…")
            case .mergingSummary:
                String(localized: "Merging Summary…")
            case .writingNote:
                String(localized: "Writing note…")
            case .stopping:
                String(localized: "Stopping…")
            }
        }

        /// The label with how long the phase has lasted, from the first whole minute: a model that
        /// does not answer shows up before its timeout.
        func label(minutes: Int) -> String {
            minutes > 0 ? String(localized: "\(label) · \(minutes) min") : label
        }
    }

    struct RecentMeeting: Identifiable, Equatable {
        let id: UUID
        let title: String
        let status: ProcessingRecord.Status
        let failureReason: String?
    }

    struct SpeakerNamingContext {
        let speakers: [Int]
        let names: [Int: String]
        let participants: [String]
        let samples: [Int: [SpeakerSample]]
        /// `nil` once the audio is deleted: the samples are then only quotes.
        let player: SpeakerSamplePlayer?
        /// `nil` once the audio is deleted: the voices can then no longer be recognised.
        let recording: Recording?
    }

    private let transcriber: LocalTranscriber
    private let diarizer: SpeakerDiarizer
    private let speechDetector: SpeechDetector
    /// Transcriptions started while recording, to be completed at the stop.
    private var liveTranscriptions: [UUID: MeetingTranscription] = [:]
    /// In-memory copy of the state of Meetings being recorded: if saving to disk fails,
    /// the Meeting is still queued at the stop.
    private var recordingRecords: [UUID: ProcessingRecord] = [:]
    /// The last Processing in the queue: the next one starts when this one ends.
    private var queueTail: Task<Void, Never>?
    /// The queued and running Processing of each Meeting, so *Stop processing* can cancel it. The
    /// token tells a stopped entry from the Retry of the same Meeting that may follow it.
    private var tasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private(set) var pendingCount = 0
    private(set) var currentTitle: String?
    private(set) var currentPhase: Phase?
    private var currentID: UUID?
    /// When the current phase began, and its whole minutes as of the last time the menu opened.
    private var phaseStartedAt: Date?
    private(set) var phaseMinutes = 0
    private(set) var lastError: String?
    private(set) var recent: [RecentMeeting] = []
    private(set) var lastNoteURL: URL?
    /// The Transcript in the Vault or, without a Vault, the copy in the Recording folder.
    private(set) var lastTranscriptURL: URL?

    init(transcriber: LocalTranscriber, diarizer: SpeakerDiarizer, speechDetector: SpeechDetector) {
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.speechDetector = speechDetector
    }

    static func directory(for takkuID: UUID) -> URL {
        MeetingRecorder.recordingsDirectory.appending(path: takkuID.uuidString, directoryHint: .isDirectory)
    }

    // MARK: - Meeting lifecycle

    func meetingStarted(
        takkuID: UUID, startedAt: Date, templateName: String, summaryProfile: ProviderProfile?,
        noteURL: URL?, transcription: MeetingTranscription
    ) {
        liveTranscriptions[takkuID] = transcription
        let record = ProcessingRecord(
            takkuID: takkuID, startedAt: startedAt, status: .recording,
            templateName: templateName, summaryProfile: summaryProfile, noteURL: noteURL
        )
        recordingRecords[takkuID] = record
        save(record)
    }

    func templateChanged(takkuID: UUID, to templateName: String) {
        guard var record = recordingRecords[takkuID] else { return }
        record.templateName = templateName
        recordingRecords[takkuID] = record
        save(record)
    }

    /// The note of the Meeting in progress was renamed (another calendar event picked in the menu).
    func noteMoved(takkuID: UUID, to noteURL: URL) {
        guard var record = recordingRecords[takkuID] else { return }
        record.noteURL = noteURL
        recordingRecords[takkuID] = record
        save(record)
    }

    func meetingStopped(takkuID: UUID) {
        guard var record = recordingRecords.removeValue(forKey: takkuID) ?? record(takkuID) else { return }
        record.status = .queued
        save(record)
        enqueueProcessing(record)
    }

    /// A Meeting made from an imported audio file: its Recording is already complete, so it is queued at once.
    /// `noteFolder` and `noteTitle` come from `takku import --folder` and `--title`.
    func meetingImported(
        takkuID: UUID, startedAt: Date, templateName: String, summaryProfile: ProviderProfile?, noteURL: URL?,
        warnings: [String], noteFolder: String? = nil, noteTitle: String? = nil, notes: String? = nil,
        languages: [String]? = nil
    ) {
        let record = ProcessingRecord(
            takkuID: takkuID, startedAt: startedAt, status: .queued,
            templateName: templateName, summaryProfile: summaryProfile, noteURL: noteURL,
            importedAt: Date(), importWarnings: warnings, noteFolder: noteFolder, noteTitle: noteTitle,
            notes: notes, languages: languages
        )
        save(record)
        enqueueProcessing(record)
    }

    /// After a restart: resumes Processing left halfway and recovers Recordings interrupted
    /// by a crash, then deletes expired audio.
    func resumeAfterLaunch() {
        let plan = ProcessingRecord.afterRestart(allRecords())
        plan.toSave.forEach(save)
        for var record in plan.toProcess {
            if record.status == .recording {
                do {
                    // Rebuilds recording.json without silently dropping a Track whose Segment list is damaged.
                    try Recording.recover(
                        fromFolder: Self.directory(for: record.takkuID), takkuID: record.takkuID, startedAt: record.startedAt
                    )
                } catch {
                    record.status = .failed(reason: String(localized: "Recording interrupted and not recoverable: \(error.localizedDescription)"))
                    save(record)
                    continue
                }
            }
            record.status = .queued
            save(record)
            enqueueProcessing(record)
        }
        cleanUpExpiredRecordings()
    }

    // MARK: - Actions from the Recent meetings menu

    func openNote(_ takkuID: UUID) {
        do {
            guard let note = try noteInVault(takkuID)?.note else {
                lastError = String(localized: "Meeting note not found in the notes folder.")
                return
            }
            Vault.openInEditor(note)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The Transcript in the Vault, or its local copy when the Meeting has none there.
    func openTranscript(_ takkuID: UUID) {
        if let vault = Vault.configured {
            do {
                if let transcript = try vault.findTranscript(takkuID: takkuID, expectedNote: record(takkuID)?.noteURL) {
                    Vault.openInEditor(transcript)
                    return
                }
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
        let local = Self.directory(for: takkuID).appending(path: Transcript.recordingCopyFileName)
        guard FileManager.default.fileExists(atPath: local.path(percentEncoded: false)) else {
            lastError = String(localized: "Transcript not found.")
            return
        }
        NSWorkspace.shared.open(local)
    }

    /// The Speakers found in the current Transcript, with the names and calendar participants
    /// already in the Meeting note.
    func speakerNamingContext(_ takkuID: UUID) -> SpeakerNamingContext? {
        do {
            guard let (vault, noteURL) = try noteInVault(takkuID),
                  let transcriptURL = try vault.findTranscript(takkuID: takkuID, expectedNote: noteURL),
                  let transcriptFile = try? String(contentsOf: transcriptURL, encoding: .utf8),
                  let note = try? vault.meetingNote(at: noteURL)
            else {
                lastError = String(localized: "Meeting note or Transcript not found in the notes folder.")
                return nil
            }
            let (transcript, _) = Transcript.parse(vaultFile: transcriptFile)
            let speakers = Array(Set(transcript.paragraphs.compactMap(\.speaker))).sorted()
            guard !speakers.isEmpty else {
                lastError = String(localized: "No Speakers found in the Transcript.")
                return nil
            }
            let directory = Self.directory(for: takkuID)
            let recording = hasRecording(takkuID) ? try? Recording.load(fromFolder: directory) : nil
            return SpeakerNamingContext(
                speakers: speakers, names: note.speakerNames, participants: note.participants,
                samples: SpeakerSample.samples(in: transcript),
                player: recording.map { SpeakerSamplePlayer(recording: $0, directory: directory) },
                recording: recording
            )
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Saves the user-owned Speaker names, then regenerates from the current Transcript so the
    /// audio and any corrections in the Vault are left alone.
    func saveSpeakerNames(
        _ names: [Int: String], for takkuID: UUID, templateName: String, profile: ProviderProfile?
    ) -> Bool {
        do {
            guard let (vault, noteURL) = try noteInVault(takkuID) else {
                lastError = String(localized: "Meeting note not found in the notes folder.")
                return false
            }
            try vault.update(noteURL) { $0.replaceSpeakerNames(with: names) }
        } catch {
            lastError = String(localized: "Speaker names not saved: \(error.localizedDescription)")
            return false
        }
        retry(takkuID, templateName: templateName, profile: profile, mode: .summary)
        return true
    }

    /// In the Editor like the notes; the copy in the Recording folder (no Vault) with the default app.
    func openLastTranscript() {
        guard let url = lastTranscriptURL else { return }
        if let vault = Vault.configured, vault.contains(url) {
            Vault.openInEditor(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func hasRecording(_ takkuID: UUID) -> Bool {
        RecordingStorage.hasAudio(Self.directory(for: takkuID))
    }

    /// Retry, with the Template and Profile chosen in the menu now: they become the Meeting's.
    /// `.summary` always uses the current Transcript in the Vault; `.recording` rebuilds it from
    /// the audio. Only for concluded Meetings: one being recorded or already queued is left alone.
    /// `forcingTemplate` (`takku regenerate`) uses `templateName` even for a failed Meeting.
    /// Returns whether the Retry was queued.
    @discardableResult
    func retry(
        _ takkuID: UUID, templateName: String, profile: ProviderProfile?, mode: RetryMode = .automatic,
        forcingTemplate: Bool = false
    ) -> Bool {
        guard var record = record(takkuID) else { return false }
        let hasAudio = hasRecording(takkuID)
        let regenerating: Bool
        let reprocessing: ProcessingRecord.Reprocessing?
        switch mode {
        case .automatic:
            (regenerating, reprocessing) = (!hasAudio, nil)
        case .summary:
            (regenerating, reprocessing) = (true, nil)
        case .recording(let fromScratch):
            guard hasAudio else {
                lastError = String(localized: "Recording not found: regenerate the Summary from the current Transcript instead.")
                return false
            }
            (regenerating, reprocessing) = (false, fromScratch ? .fromScratch : .reusingCache)
        }
        record.templateName = forcingTemplate ? templateName : record.retryTemplate(chosen: templateName)
        record.summaryProfile = profile
        record.reprocessing = reprocessing
        do {
            if regenerating { try record.beginRegeneration() } else { try record.queueForRetry() }
        } catch {
            return false
        }
        lastError = nil
        // Once accepted and before enqueueing, so the count leaves this Retry out.
        logger.notice("""
            Retry \(takkuID, privacy: .public): \(regenerating ? "Regeneration" : "full Processing", privacy: .public)\
            \(reprocessing.map { " (\($0.rawValue))" } ?? "", privacy: .public), \
            Template \(record.templateName, privacy: .private), model \(profile?.model ?? "none", privacy: .public), \
            \(self.pendingCount) ahead in the queue
            """)
        save(record)
        if regenerating {
            enqueue(takkuID) { await self.runRegeneration(record) }
        } else {
            enqueueProcessing(record)
        }
        return true
    }

    /// The Processing state of a Meeting, as saved (`takku regenerate`).
    func processingRecord(_ takkuID: UUID) -> ProcessingRecord? {
        record(takkuID)
    }

    /// *Stop processing*: a queued Meeting leaves the queue at once; the running one stops at the
    /// end of its current step (a request to the model is cancelled, a transcription in progress
    /// finishes first) and writes nothing more. A Retry gives the Meeting back as it was; a
    /// Meeting never processed fails, with its audio kept for *Reprocess Recording…*.
    func stop(_ takkuID: UUID) {
        guard let entry = tasks[takkuID] else { return }
        entry.task.cancel()
        let isRunning = currentID == takkuID
        logger.notice("Stop \(takkuID, privacy: .public) \(isRunning ? "while running" : "while queued", privacy: .public)")
        if isRunning {
            update(.stopping, for: takkuID)
            return
        }
        // Its task only waits for the one before it to end, then returns without working.
        tasks[takkuID] = nil
        pendingCount -= 1
        guard var record = record(takkuID) else { return }
        try? record.stop(reason: Self.stoppedReason)
        save(record)
    }

    /// The Processing shown in the menu, the one running.
    func stopCurrent() {
        if let currentID { stop(currentID) }
    }

    private static var stoppedReason: String {
        String(localized: "Processing stopped: Reprocess Recording to try again.")
    }

    /// Called when the menu opens: it shows how long the current phase has lasted.
    func refreshPhaseMinutes() {
        let minutes = phaseStartedAt.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
        if minutes != phaseMinutes { phaseMinutes = minutes }
    }

    #if DEBUG
    /// Reprocesses a Recording of the data folder (automated tests) and waits for the end.
    func reprocess(_ directory: URL) async -> URL? {
        guard let recording = try? Recording.load(fromFolder: directory),
              Self.directory(for: recording.meetingID).standardizedFileURL == directory.standardizedFileURL
        else {
            lastError = "Reprocessing refused: the folder is not in Takku's data folder."
            return nil
        }
        if record(recording.meetingID) == nil {
            save(ProcessingRecord(
                takkuID: recording.meetingID, startedAt: recording.startedAt, status: .completed,
                templateName: AppSettings.defaultTemplate, summaryProfile: AppSettings.activeProviderProfile, noteURL: nil
            ))
        }
        retry(
            recording.meetingID,
            templateName: record(recording.meetingID)?.templateName ?? AppSettings.defaultTemplate,
            profile: AppSettings.activeProviderProfile
        )
        await waitUntilIdle()
        return lastTranscriptURL
    }

    func waitUntilIdle() async {
        await queueTail?.value
    }
    #endif

    // MARK: - Queue

    private func show(_ phase: Phase, for record: ProcessingRecord) {
        currentID = record.takkuID
        currentTitle = record.noteURL?.deletingPathExtension().lastPathComponent
            ?? record.startedAt.formatted(date: .abbreviated, time: .shortened)
        setPhase(phase)
    }

    private func update(_ phase: Phase, for takkuID: UUID) {
        // A step reporting its progress does not hide that a Stop is on its way.
        guard currentID == takkuID, currentPhase != .stopping else { return }
        setPhase(phase)
    }

    private func setPhase(_ phase: Phase?) {
        guard phase != currentPhase else { return }
        currentPhase = phase
        phaseStartedAt = phase == nil ? nil : Date()
        if phaseMinutes != 0 { phaseMinutes = 0 }
    }

    /// The Processing shown in the menu is over, finished or stopped.
    private func clearCurrent() {
        currentID = nil
        currentTitle = nil
        setPhase(nil)
    }

    private func update(_ progress: Summarizer.Progress, for takkuID: UUID) {
        switch progress {
        case .writing(let part, let total):
            update(.writingSummary(part: part, total: total), for: takkuID)
        case .merging:
            update(.mergingSummary, for: takkuID)
        }
    }

    private func enqueueProcessing(_ record: ProcessingRecord) {
        enqueue(record.takkuID) { await self.process(record) }
    }

    private func enqueue(_ takkuID: UUID, _ work: @escaping @MainActor () async -> Void) {
        pendingCount += 1
        let previous = queueTail
        let token = UUID()
        let task = Task {
            await previous?.value
            // Stopped while queued: `stop` has already given the Meeting back and counted it out.
            guard !Task.isCancelled else { return }
            await work()
            pendingCount -= 1
            if tasks[takkuID]?.token == token { tasks[takkuID] = nil }
        }
        tasks[takkuID] = (token, task)
        queueTail = task
    }

    private func process(_ queued: ProcessingRecord) async {
        // The state on disk may be newer (e.g. Template changed), otherwise the queued one applies.
        var record = record(queued.takkuID) ?? queued
        record.status = .processing
        show(.transcribing(part: 0, total: 0), for: record)
        save(record)
        let started = ContinuousClock.now
        logger.notice("Processing \(record.takkuID, privacy: .public) started")
        let directory = Self.directory(for: record.takkuID)
        // An import given its languages (`takku import --language`) keeps them, also when reprocessed.
        let transcription = liveTranscriptions.removeValue(forKey: record.takkuID)
            ?? MeetingTranscription(
                transcriber: transcriber, diarizer: diarizer, speechDetector: speechDetector, model: .selected,
                languages: record.languages ?? AppSettings.meetingLanguages
            )

        let recording: Recording
        do {
            recording = try Recording.load(fromFolder: directory)
        } catch {
            finish(&record, problems: [String(localized: "Recording unreadable: \(error.localizedDescription)")], warnings: [], started: started)
            return
        }

        update(.transcribing(part: 0, total: recording.segments.count), for: record.takkuID)
        let takkuID = record.takkuID
        await transcription.setPhaseHandler { [weak self] phase in
            Task { @MainActor in
                switch phase {
                case .transcribing(let part, let total):
                    self?.update(.transcribing(part: part, total: total), for: takkuID)
                case .preparingSpeakers:
                    self?.update(.preparingSpeakers, for: takkuID)
                case .identifyingSpeakers:
                    self?.update(.identifyingSpeakers, for: takkuID)
                }
            }
        }

        // Read once per Processing: a change counts from the next Meeting, or from a Retry.
        let vocabulary = TakkuFolder.vocabulary()
        var problems: [String] = []
        // An unreadable Segment (e.g. the one open during a crash) leaves a gap in the
        // Transcript but does not prevent the Summary: it is a warning, not a failure.
        var warnings = record.importWarnings ?? []
        let finished: MeetingTranscription.Finished?
        do {
            finished = try await transcription.finish(
                recording, in: directory, vocabulary: vocabulary, ignoringCache: record.ignoresTranscriptionCache
            )
            if let failedSegments = finished?.failedSegments, !failedSegments.isEmpty {
                warnings.append(String(localized: "Incomplete transcript: \(failedSegments.joined(separator: "; "))"))
            }
            if let speakersProblem = finished?.speakersProblem {
                warnings.append(String(localized: "Speakers not told apart: \(speakersProblem)"))
            }
            if let language = finished?.untickedLanguage {
                let name = MeetingLanguages.name(language)
                warnings.append(String(localized: "Some of the meeting is in \(name), not among the meeting languages: it is transcribed anyway. Tick \(name) in Settings → Transcription."))
            }
            if let cacheProblems = finished?.cacheProblems, !cacheProblems.isEmpty {
                warnings.append(String(localized: "Cache not saved; this Processing's result is preserved: \(cacheProblems.joined(separator: "; "))"))
            }
            lastTranscriptURL = finished?.url
            logger.notice("Transcript ready after \(secondsSince(started), privacy: .public)")
        } catch {
            finished = nil
            problems.append(String(localized: "Transcription failed: \(error.localizedDescription)"))
        }
        if Task.isCancelled {
            stopped(&record, started: started)
            return
        }

        if let vault = Vault.configured {
            update(finished == nil ? .writingNote : .writingSummary(part: 0, total: 0), for: record.takkuID)
            do {
                let (noteURL, summaryProblem) = try await writeToVault(
                    vault, finished, recording: recording, record: record, vocabulary: vocabulary
                )
                record.noteURL = noteURL
                lastNoteURL = noteURL
                if let summaryProblem { problems.append(summaryProblem) }
            } catch is CancellationError {
                stopped(&record, started: started)
                return
            } catch {
                problems.append(String(localized: "Writing to the notes folder failed: \(error.localizedDescription)"))
            }
        } else {
            update(.writingNote, for: record.takkuID)
            warnings.append(String(localized: "No notes folder chosen: no Summary, the Transcript is only in the Recording folder."))
        }
        finish(&record, problems: problems, warnings: warnings, started: started, rebuild: rebuildDescription(record, finished))
    }

    /// For a Reprocess, how the Transcript was rebuilt: otherwise the notification would look
    /// like a new Summary only.
    private func rebuildDescription(_ record: ProcessingRecord, _ finished: MeetingTranscription.Finished?) -> String? {
        guard let reprocessing = record.reprocessing, let finished else { return nil }
        switch reprocessing {
        case .fromScratch:
            return String(localized: "Transcribed again from scratch, voices included.")
        case .reusingCache:
            return String(localized: "Transcript rebuilt from the audio. Segments transcribed again: \(finished.segmentsTranscribed); from the saved transcription: \(finished.segmentsFromCache).")
        }
    }

    private func runRegeneration(_ queued: ProcessingRecord) async {
        var record = queued
        let takkuID = record.takkuID
        let started = ContinuousClock.now
        show(.writingSummary(part: 0, total: 0), for: record)
        logger.notice("Regeneration \(takkuID, privacy: .public) started")
        let vault: Vault
        var noteURL: URL
        let transcriptURL: URL
        let transcriptFile: String
        do {
            guard let configured = Vault.configured,
                  let foundNote = try configured.findMeetingNote(takkuID: takkuID, expected: record.noteURL),
                  let foundTranscript = try configured.findTranscript(takkuID: takkuID, expectedNote: foundNote)
            else {
                finish(&record, problems: [String(localized: "Retry not possible: the audio is deleted and the Meeting note or Transcript is not in the notes folder.")], warnings: [], started: started)
                return
            }
            vault = configured
            noteURL = foundNote
            transcriptURL = foundTranscript
            transcriptFile = try String(contentsOf: transcriptURL, encoding: .utf8)
        } catch {
            finish(&record, problems: [String(localized: "Retry failed: \(error.localizedDescription)")], warnings: [], started: started)
            return
        }

        var problems: [String] = []
        do {
            let (transcript, language) = Transcript.parse(vaultFile: transcriptFile)
            let summaryProblem: String?
            (noteURL, summaryProblem) = try await writeSummary(
                transcript, language: language, into: noteURL, record: record, vault: vault, vocabulary: TakkuFolder.vocabulary()
            ) { noteURL, summary, speakerNames in
                // Only the labels: the text of a Transcript already in the Vault is the user's.
                // Read it again after the model wait, so edits made meanwhile are not restored
                // to the older version used for the request.
                let currentTranscriptFile = try String(contentsOf: transcriptURL, encoding: .utf8)
                let currentTranscript = Transcript.parse(vaultFile: currentTranscriptFile).transcript
                if let relabeled = Transcript.relabeling(vaultFile: currentTranscriptFile, names: speakerNames) {
                    try relabeled.write(to: transcriptURL, atomically: true, encoding: .utf8)
                }
                try vault.update(noteURL) {
                    $0.recordRegeneration(
                        takkuID: takkuID, transcriptName: transcriptURL.deletingPathExtension().lastPathComponent,
                        summary: summary, screenshots: currentTranscript.screenshots
                    )
                }
            }
            if let summaryProblem { problems.append(summaryProblem) }
            record.noteURL = noteURL
            lastNoteURL = noteURL
        } catch is CancellationError {
            stopped(&record, started: started)
            return
        } catch {
            problems.append(String(localized: "Retry failed: \(error.localizedDescription)"))
        }
        finish(&record, problems: problems, warnings: [], started: started)
    }

    /// The end of a Processing stopped from the menu: no notification, the user asked for it.
    private func stopped(_ record: inout ProcessingRecord, started: ContinuousClock.Instant) {
        let takkuID = record.takkuID
        logger.notice("Processing \(takkuID, privacy: .public) stopped after \(secondsSince(started), privacy: .public)")
        try? record.stop(reason: Self.stoppedReason)
        save(record)
        clearCurrent()
    }

    private func finish(
        _ record: inout ProcessingRecord, problems: [String], warnings: [String], started: ContinuousClock.Instant,
        rebuild: String? = nil
    ) {
        let noteName = record.noteURL?.deletingPathExtension().lastPathComponent ?? String(localized: "Meeting")
        let takkuID = record.takkuID
        logger.notice("""
            Processing \(takkuID, privacy: .public) \(problems.isEmpty ? "completed" : "failed", privacy: .public) \
            in \(secondsSince(started), privacy: .public)
            """)
        if problems.isEmpty {
            record.status = .completed
            lastError = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        } else {
            let reason = problems.joined(separator: " ")
            record.status = .failed(reason: reason)
            lastError = reason
            logger.error("Processing failed: \(reason, privacy: .private)")
        }
        // Without a note, this Meeting's own local Transcript: `lastTranscriptURL` may belong to an
        // earlier Meeting when this one's transcription failed.
        let localTranscript = Self.directory(for: takkuID).appending(path: Transcript.recordingCopyFileName)
        let opened = record.noteURL
            ?? (FileManager.default.fileExists(atPath: localTranscript.path(percentEncoded: false)) ? localTranscript : nil)
        let speakers = transcriptSpeakers(record)
        Notifications.shared.processingFinished(
            meeting: takkuID, noteName: noteName, note: opened, hasVault: Vault.configured != nil,
            hasSummary: record.summaryProfile != nil, problems: problems, warnings: warnings, rebuild: rebuild,
            unnamedSpeakers: problems.isEmpty ? speakers ?? 0 : 0, canRegenerate: !problems.isEmpty && speakers != nil
        )
        record.reprocessing = nil
        record.statusBeforeRetry = nil
        save(record)
        clearCurrent()
        // After every completed Processing, Retry included, so the Hook can update what it sent.
        if problems.isEmpty, HookRunner.isInstalled, let vault = Vault.configured, let noteURL = record.noteURL {
            do {
                if let transcriptURL = try vault.findTranscript(takkuID: record.takkuID, expectedNote: noteURL) {
                    HookRunner.shared.run(note: noteURL, transcript: transcriptURL, vault: vault.root)
                }
            } catch {
                lastError = String(localized: "Hook not run: \(error.localizedDescription)")
                logger.error("Hook not run: \(error, privacy: .private)")
            }
        }
    }

    // MARK: - Vault and Summary

    /// Writes the outcome of Processing into the Vault: Summary, title and rename, Transcript,
    /// Meeting note. Returns the note and, if there was one, the Summary problem.
    private func writeToVault(
        _ vault: Vault, _ finished: MeetingTranscription.Finished?, recording: Recording, record: ProcessingRecord,
        vocabulary: Vocabulary
    ) async throws -> (URL, String?) {
        let noteURL = try vault.findMeetingNote(takkuID: record.takkuID, expected: record.noteURL)
            ?? vault.createMeetingNote(
                takkuID: record.takkuID, startedAt: record.startedAt, folder: record.noteFolder, title: record.noteTitle,
                personalNotes: record.notes
            )
        guard let finished else {
            try vault.update(noteURL) {
                $0.recordFailure(
                    takkuID: record.takkuID,
                    reason: String(localized: "Transcription failed: the Recording is saved, you can retry.")
                )
            }
            return (noteURL, nil)
        }

        // Resolve Sync duplicates before a Summary wait or provisional rename: a conflict must not
        // strand processing.json at the old note path or do expensive work that cannot be committed.
        _ = try vault.findTranscript(takkuID: record.takkuID, expectedNote: noteURL)
        let directory = Self.directory(for: record.takkuID)
        let screenshots = Screenshot.load(fromFolder: directory)
        try vault.copyScreenshots(screenshots, fromRecordingFolder: directory)
        let transcript = finished.transcript.withScreenshots(screenshots)
        return try await writeSummary(
            transcript, language: finished.language, into: noteURL, record: record, vault: vault,
            vocabulary: vocabulary
        ) { noteURL, summary, speakerNames in
            // Written after the rename: a new Transcript is named after the note's final name.
            let transcriptURL = try vault.writeTranscript(
                transcript.naming(speakerNames),
                takkuID: record.takkuID,
                meetingNote: noteURL,
                meetingNoteName: noteURL.deletingPathExtension().lastPathComponent,
                language: finished.language
            )
            lastTranscriptURL = transcriptURL
            try vault.update(noteURL) {
                $0.recordProcessing(
                    takkuID: record.takkuID,
                    duration: recording.endedAt.timeIntervalSince(recording.startedAt),
                    language: finished.language,
                    transcriptName: transcriptURL.deletingPathExtension().lastPathComponent,
                    summary: summary, screenshots: screenshots
                )
            }
        }
    }

    /// Generates the Summary with the Meeting's Template and Profile, renames a note still
    /// provisional with the title, lets `writeNote` write the note where it now is (with the Speaker
    /// names the note gives now), and shows the renamed note in Obsidian. Returns where the note is
    /// and the Summary problem, if any.
    private func writeSummary(
        _ transcript: Transcript, language: String?, into noteURL: URL, record: ProcessingRecord, vault: Vault,
        vocabulary: Vocabulary,
        writeNote: (URL, MeetingNote.SummaryOutcome, [Int: String]) throws -> Void
    ) async throws -> (URL, String?) {
        // Read now, not at the start: the user may have named Speakers or fixed the participants.
        let note = try vault.meetingNote(at: noteURL)
        let speakerNames = note.speakerNames
        // A note named after its calendar event, or renamed by the user, keeps its name: no title to ask for.
        let wantsTitle = vault.isInNoteFolder(noteURL, folder: record.noteFolder) && VaultNaming.renamedNoteName(
            current: noteURL.deletingPathExtension().lastPathComponent, startedAt: record.startedAt, title: VaultNaming.defaultTitle
        ) != nil
        let template = TakkuFolder.template(named: record.templateName)
        let (summary, title, log) = await summarize(
            transcript.naming(speakerNames), language: language, personalNotes: note.personalNotes,
            participants: note.participants, wantsTitle: wantsTitle,
            template: template, profile: record.summaryProfile, vocabulary: vocabulary,
            onProgress: { [weak self] progress in
                Task { @MainActor in self?.update(progress, for: record.takkuID) }
            }
        )
        // Stopped while the model was writing: the note stays as it was; the log keeps the request.
        if Task.isCancelled {
            if let log {
                await writeSummaryLog(log, summary: summary, noteURL: noteURL, template: template.name, record: record)
            }
            throw CancellationError()
        }
        let rename = renameIfProvisional(noteURL, title: title, record: record, in: vault)
        if let log {
            await writeSummaryLog(log, summary: summary, noteURL: rename.url, template: template.name, record: record)
        }
        if rename.url != noteURL { try? await Task.sleep(for: Vault.settleAfterRename) }
        // Do not replace a good Transcript and Summary with a failed Retry. The error stays in
        // Processing's status and notification; the previous result remains usable in the Vault.
        if case .failed(let reason) = summary,
           (try? vault.meetingNote(at: rename.url))?.hasSuccessfulOutcome == true {
            return (rename.url, String(localized: "Summary not generated: \(reason)"))
        }
        update(.writingNote, for: record.takkuID)
        try writeNote(rename.url, summary, speakerNames)
        if rename.follow { RenamedNoteFollower.follow(rename.url, in: vault) }
        if case .failed(let reason) = summary {
            return (rename.url, String(localized: "Summary not generated: \(reason)"))
        }
        return (rename.url, nil)
    }

    /// Renames with the title a note still in place and with its provisional name. Returns where
    /// the note is and whether Obsidian must be shown the renamed note (it was showing it). If the
    /// rename fails the note stays as it is: the Summary must not be lost over a name.
    private func renameIfProvisional(
        _ noteURL: URL, title: String?, record: ProcessingRecord, in vault: Vault
    ) -> (url: URL, follow: Bool) {
        guard let title, vault.isInNoteFolder(noteURL, folder: record.noteFolder),
              let newName = VaultNaming.renamedNoteName(
                  current: noteURL.deletingPathExtension().lastPathComponent, startedAt: record.startedAt, title: title
              )
        else { return (noteURL, false) }
        // Read before the rename: afterwards Obsidian may already show another note.
        let wasShownInObsidian = vault.isShownInObsidian(noteURL) ?? true
        do {
            let renamed = try vault.rename(noteURL, to: newName)
            return (renamed, wasShownInObsidian && AppSettings.opensNotes)
        } catch {
            logger.error("Renaming the note failed: \(error, privacy: .private)")
            return (noteURL, false)
        }
    }

    /// Summary and title for the rename, and the requests made for them if the Summary log is on.
    /// A missing title is not an error: the note keeps its provisional name.
    private func summarize(
        _ transcript: Transcript, language: String?, personalNotes: String, participants: [String], wantsTitle: Bool,
        template: Template, profile: ProviderProfile?, vocabulary: Vocabulary,
        onProgress: @escaping @Sendable (Summarizer.Progress) -> Void = { _ in }
    ) async -> (MeetingNote.SummaryOutcome, String?, SummaryRequests?) {
        var profile = profile
        var isTestProfile = false
        #if DEBUG
        if let testProfile = AppSettings.testSummaryProfile {
            profile = testProfile
            isTestProfile = true
        }
        #endif
        // No Profile chosen ("Transcript" in the menu): no Summary and no Template, only the Transcript,
        // with a title from Apple Intelligence when the Mac has it, so the note is not just "Meeting".
        guard let profile else {
            let title = wantsTitle ? await appleIntelligenceTitle(transcript, language: language, vocabulary: vocabulary) : nil
            return (.transcriptOnly, title, nil)
        }
        // A Profile deleted after the Meeting started has lost its key in the Keychain too.
        guard isTestProfile || AppSettings.summaryProfiles.contains(where: { $0.id == profile.id }) else {
            return (.failed(reason: String(localized: "the Profile \"\(profile.displayName)\" was deleted: choose another one in the menu and Retry.")), nil, nil)
        }
        // The key is looked up by the Profile's id and sent to the address of the Meeting's copy of it: if the
        // Profile's address was edited since, or the copy on disk was, the key would go to the old one.
        guard isTestProfile || AppSettings.summaryProfiles.first(where: { $0.id == profile.id })?.baseURL.trimmingCharacters(in: .whitespaces)
            == profile.baseURL.trimmingCharacters(in: .whitespaces)
        else {
            return (.failed(reason: String(localized: "the address of the Profile \"\(profile.displayName)\" changed since this Meeting: Retry to use the new one.")), nil, nil)
        }
        guard !transcript.paragraphs.isEmpty else {
            return (.failed(reason: String(localized: "there is no speech in the Recording.")), nil, nil)
        }
        let log = AppSettings.keepSummaryLog ? SummaryRequests(recorder: SummaryLog.Recorder(), profile: profile) : nil
        let started = ContinuousClock.now
        logger.notice("Summary started: \(transcript.paragraphs.count) paragraphs, model \(profile.model, privacy: .public)")
        do {
            let client = try ChatClient(profile: profile)
            var prompt = SummaryPrompt(
                template: template, personalNotes: personalNotes, transcript: transcript, meetingLanguage: language,
                vocabulary: vocabulary, userName: NSFullUserName(), participants: participants
            )
            prompt.replyRoom = profile.replyReserveTokens
            // Apple Intelligence's context is the system's, which grows with macOS: read now, not stored.
            let context = profile.isAppleIntelligence ? AppleIntelligenceModel.contextTokens : profile.maxContextTokens
            let summary = try await Summarizer(
                client: client, maxContextTokens: context, isReportedContext: profile.isAppleIntelligence,
                log: log?.recorder, onProgress: onProgress
            )
                .summarize(prompt)
            logger.notice("Summary written in \(secondsSince(started), privacy: .public)")
            // On the text alone: the Screenshots' names would reach the model.
            let titleRequest = MeetingTitle.request(summary: summary.text, language: prompt.summaryLanguage, vocabulary: vocabulary)
            let localTitleRequest = MeetingTitle.request(
                summary: summary.text, language: prompt.summaryLanguage, vocabulary: vocabulary,
                excerptCharacters: MeetingTitle.localSummaryExcerptCharacters
            )
            var title: String?
            if wantsTitle {
                // A Summary paid by tokens gets its title free on this Mac when Apple Intelligence is there;
                // if it fails or answers nothing, the Profile writes it. Not in the Summary log, which is
                // the Profile's requests.
                if !profile.isAppleIntelligence, let local = AppleIntelligenceModel.client() {
                    title = (try? await local.complete(localTitleRequest)).flatMap(MeetingTitle.clean)
                    logger.notice("Title from Apple Intelligence: \(title == nil ? "empty, asking the Profile" : "written", privacy: .public)")
                }
                if title == nil {
                    let titleClient = log.map { client.recording(into: $0.recorder, as: .title) } ?? client
                    title = (try? await titleClient.complete(titleRequest)).flatMap(MeetingTitle.clean)
                }
            }
            return (
                .written(text: summary.withScreenshots, template: template.name, provider: profile.displayName),
                title, log
            )
        } catch {
            logger.error("Summary not generated after \(secondsSince(started), privacy: .public): \(error.localizedDescription, privacy: .private)")
            return (.failed(reason: error.localizedDescription), nil, log)
        }
    }

    /// The title of a Meeting without a Summary, from the start of its Transcript, by Apple
    /// Intelligence on this Mac; `nil` without it, without speech, or if it fails.
    private func appleIntelligenceTitle(_ transcript: Transcript, language: String?, vocabulary: Vocabulary) async -> String? {
        guard !transcript.paragraphs.isEmpty, let client = AppleIntelligenceModel.client() else { return nil }
        let request = MeetingTitle.request(transcript: transcript, language: language ?? "it", vocabulary: vocabulary)
        do {
            let title = MeetingTitle.clean(try await client.complete(request))
            logger.notice("Title without a Summary from Apple Intelligence: \(title == nil ? "empty" : "written", privacy: .public)")
            return title
        } catch {
            logger.error("Title without a Summary not written: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// The requests of one Summary, with the Profile that made them.
    private struct SummaryRequests {
        let recorder: SummaryLog.Recorder
        let profile: ProviderProfile
    }

    /// Writes the Summary's requests to the Summary log, under the note's name after the rename.
    /// A Summary that never reached the model leaves nothing.
    private func writeSummaryLog(
        _ log: SummaryRequests, summary: MeetingNote.SummaryOutcome, noteURL: URL, template: String, record: ProcessingRecord
    ) async {
        let calls = await log.recorder.calls
        guard !calls.isEmpty else { return }
        let error: String? = if case .failed(let reason) = summary { reason } else { nil }
        SummaryLogStorage.write(SummaryLog.Entry(
            takkuID: record.takkuID, meetingNote: noteURL.deletingPathExtension().lastPathComponent,
            meetingStartedAt: record.startedAt, template: template, profile: log.profile, error: error, calls: calls,
            writtenAt: Date()
        ))
    }

    // MARK: - State on disk

    /// The Vault and the Meeting's note in it, also after the user renamed or moved it; `nil`
    /// without a Vault or without the note.
    /// For the notification at the end: `nil` without the note and its Transcript in the Vault,
    /// otherwise how many of the Transcript's Speakers the note does not name.
    private func transcriptSpeakers(_ record: ProcessingRecord) -> Int? {
        guard let (vault, noteURL) = try? noteInVault(record.takkuID),
              let transcriptURL = try? vault.findTranscript(takkuID: record.takkuID, expectedNote: noteURL),
              let transcriptFile = try? String(contentsOf: transcriptURL, encoding: .utf8)
        else { return nil }
        let names = (try? vault.meetingNote(at: noteURL))?.speakerNames ?? [:]
        return Transcript.parse(vaultFile: transcriptFile).transcript.unnamedSpeakers(names: names).count
    }

    private func noteInVault(_ takkuID: UUID) throws -> (vault: Vault, note: URL)? {
        guard let vault = Vault.configured,
              let note = try vault.findMeetingNote(takkuID: takkuID, expected: record(takkuID)?.noteURL)
        else { return nil }
        return (vault, note)
    }

    private func record(_ takkuID: UUID) -> ProcessingRecord? {
        guard let record = try? ProcessingRecord.load(fromFolder: Self.directory(for: takkuID)),
              record.takkuID == takkuID
        else { return nil }
        return record
    }

    private func save(_ record: ProcessingRecord) {
        do {
            try record.save(inFolder: Self.directory(for: record.takkuID))
        } catch {
            logger.error("Processing state not saved: \(error.logCode, privacy: .public) \(error, privacy: .private)")
            lastError = String(localized: "Meeting state not saved to disk: a restart now would not resume it. \(error.localizedDescription)")
        }
        refreshRecent()
    }

    private func allRecords() -> [ProcessingRecord] {
        recordingFolders().compactMap { folder in
            guard let takkuID = UUID(uuidString: folder.lastPathComponent),
                  let record = try? ProcessingRecord.load(fromFolder: folder),
                  record.takkuID == takkuID
            else { return nil }
            return record
        }
    }

    private func recordingFolders() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: MeetingRecorder.recordingsDirectory, includingPropertiesForKeys: nil)) ?? []
    }

    /// The last five Meetings whose note is still in the Vault: a Meeting deleted from the Vault
    /// is gone from the menu too (its Recording stays until the audio expires). Meetings not
    /// concluded yet, and those recorded without a Vault, are always listed. The title is the
    /// note's current name, also after a rename in Obsidian.
    func refreshRecent() {
        let vault = Vault.configured
        // Read only if a note is not where Takku left it.
        lazy var notesByTakkuID = vault?.meetingNotesByTakkuID() ?? [:]
        var meetings: [RecentMeeting] = []
        for record in allRecords().sorted(by: { $0.recentAt > $1.recentAt }) where meetings.count < 5 {
            var note = record.noteURL
            var lookupProblem: String?
            if let vault, let expected = record.noteURL, !record.status.isPending,
               !FileManager.default.fileExists(atPath: expected.path(percentEncoded: false)) {
                guard let matches = notesByTakkuID[record.takkuID] else { continue }
                do {
                    guard let moved = try vault.uniqueMatch(matches, takkuID: record.takkuID) else { continue }
                    note = moved
                } catch {
                    lookupProblem = error.localizedDescription
                }
            }
            let title = note?.deletingPathExtension().lastPathComponent
                ?? record.startedAt.formatted(date: .abbreviated, time: .shortened)
            let statusFailure: String? = if case .failed(let reason) = record.status { reason } else { nil }
            meetings.append(RecentMeeting(id: record.takkuID, title: title, status: record.status, failureReason: lookupProblem ?? statusFailure))
        }
        // Unchanged most of the time: assigning would rebuild the menu anyway.
        if meetings != recent { recent = meetings }
    }

    /// Damaged Recording folders already shown in the menu by a previous cleanup.
    private static let reportedCleanupProblemsKey = "reportedCleanupProblems"

    /// Deletes the audio of expired Recordings (see `RecordingStorage.deleteAudio(olderThanDays:)`).
    /// A damaged folder is shown in the menu once, not at every launch and every day: it stays in
    /// the log and in Settings → Recordings → *Delete audio…*.
    func cleanUpExpiredRecordings() {
        let problems = RecordingStorage.deleteAudio(olderThanDays: AppSettings.retentionDays)
        for problem in problems { logger.error("Cleanup: \(problem, privacy: .private)") }
        let reported = Set(UserDefaults.standard.stringArray(forKey: Self.reportedCleanupProblemsKey) ?? [])
        UserDefaults.standard.set(problems, forKey: Self.reportedCleanupProblemsKey)
        let new = problems.filter { !reported.contains($0) }
        if !new.isEmpty { lastError = new.joined(separator: " ") }
        refreshRecent()
    }
}
