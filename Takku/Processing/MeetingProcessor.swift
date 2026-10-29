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
            }
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
    /// Transcriptions started while recording, to be completed at the stop.
    private var liveTranscriptions: [UUID: MeetingTranscription] = [:]
    /// In-memory copy of the state of Meetings being recorded: if saving to disk fails,
    /// the Meeting is still queued at the stop.
    private var recordingRecords: [UUID: ProcessingRecord] = [:]
    /// The last Processing in the queue: the next one starts when this one ends.
    private var queueTail: Task<Void, Never>?
    private(set) var pendingCount = 0
    private(set) var currentTitle: String?
    private(set) var currentPhase: Phase?
    private var currentID: UUID?
    private(set) var lastError: String?
    private(set) var recent: [RecentMeeting] = []
    private(set) var lastNoteURL: URL?
    /// The Transcript in the Vault or, without a Vault, the copy in the Recording folder.
    private(set) var lastTranscriptURL: URL?

    init(transcriber: LocalTranscriber, diarizer: SpeakerDiarizer) {
        self.transcriber = transcriber
        self.diarizer = diarizer
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
    func meetingImported(
        takkuID: UUID, startedAt: Date, templateName: String, summaryProfile: ProviderProfile?, noteURL: URL?,
        warnings: [String]
    ) {
        let record = ProcessingRecord(
            takkuID: takkuID, startedAt: startedAt, status: .queued,
            templateName: templateName, summaryProfile: summaryProfile, noteURL: noteURL,
            importedAt: Date(), importWarnings: warnings
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
                    try recoverRecording(record, in: Self.directory(for: record.takkuID))
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
            guard let vault = Vault.configured,
                  let note = try vault.findMeetingNote(takkuID: takkuID, expected: record(takkuID)?.noteURL)
            else {
                lastError = String(localized: "Meeting note not found in the Vault.")
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
            guard let vault = Vault.configured,
                  let noteURL = try vault.findMeetingNote(takkuID: takkuID, expected: record(takkuID)?.noteURL),
                  let transcriptURL = try vault.findTranscript(takkuID: takkuID, expectedNote: noteURL),
                  let transcriptFile = try? String(contentsOf: transcriptURL, encoding: .utf8),
                  let note = try? vault.meetingNote(at: noteURL)
            else {
                lastError = String(localized: "Meeting note or Transcript not found in the Vault.")
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
            guard let vault = Vault.configured,
                  let noteURL = try vault.findMeetingNote(takkuID: takkuID, expected: record(takkuID)?.noteURL)
            else {
                lastError = String(localized: "Meeting note not found in the Vault.")
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
    func retry(_ takkuID: UUID, templateName: String, profile: ProviderProfile?, mode: RetryMode = .automatic) {
        guard var record = record(takkuID) else { return }
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
                return
            }
            (regenerating, reprocessing) = (false, fromScratch ? .fromScratch : .reusingCache)
        }
        record.templateName = record.retryTemplate(chosen: templateName)
        record.summaryProfile = profile
        record.reprocessing = reprocessing
        do {
            if regenerating { try record.beginRegeneration() } else { try record.queueForRetry() }
        } catch {
            return
        }
        lastError = nil
        // Once accepted and before enqueueing, so the count leaves this Retry out.
        logger.notice("""
            Retry \(takkuID, privacy: .public): \(regenerating ? "Regeneration" : "full Processing", privacy: .public)\
            \(reprocessing.map { " (\($0.rawValue))" } ?? "", privacy: .public), \
            Template \(record.templateName, privacy: .public), model \(profile?.model ?? "none", privacy: .public), \
            \(self.pendingCount) ahead in the queue
            """)
        save(record)
        if regenerating {
            enqueue { await self.runRegeneration(record) }
        } else {
            enqueueProcessing(record)
        }
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
        currentPhase = phase
    }

    private func update(_ phase: Phase, for takkuID: UUID) {
        guard currentID == takkuID else { return }
        currentPhase = phase
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
        enqueue { await self.process(record) }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        pendingCount += 1
        let previous = queueTail
        queueTail = Task {
            await previous?.value
            await work()
            pendingCount -= 1
        }
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
        let transcription = liveTranscriptions.removeValue(forKey: record.takkuID)
            ?? MeetingTranscription(
                transcriber: transcriber, diarizer: diarizer, model: .selected, languages: AppSettings.meetingLanguages
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
        var warnings = record.importWarnings
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
            if let cacheProblems = finished?.cacheProblems, !cacheProblems.isEmpty {
                warnings.append(String(localized: "Cache not saved; this Processing's result is preserved: \(cacheProblems.joined(separator: "; "))"))
            }
            lastTranscriptURL = finished?.url
            logger.notice("Transcript ready after \(secondsSince(started), privacy: .public)")
        } catch {
            finished = nil
            problems.append(String(localized: "Transcription failed: \(error.localizedDescription)"))
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
            } catch {
                problems.append(String(localized: "Writing to the Vault failed: \(error.localizedDescription)"))
            }
        } else {
            update(.writingNote, for: record.takkuID)
            warnings.append(String(localized: "No Vault configured: no Summary, the Transcript is only in the Recording folder."))
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
                finish(&record, problems: [String(localized: "Retry not possible: the audio is deleted and the Meeting note or Transcript is not in the Vault.")], warnings: [], started: started)
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
        } catch {
            problems.append(String(localized: "Retry failed: \(error.localizedDescription)"))
        }
        finish(&record, problems: problems, warnings: [], started: started)
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
            logger.error("\(reason, privacy: .public)")
        }
        // Without a note, this Meeting's own local Transcript: `lastTranscriptURL` may belong to an
        // earlier Meeting when this one's transcription failed.
        let localTranscript = Self.directory(for: takkuID).appending(path: Transcript.recordingCopyFileName)
        let opened = record.noteURL
            ?? (FileManager.default.fileExists(atPath: localTranscript.path(percentEncoded: false)) ? localTranscript : nil)
        Notifications.shared.processingFinished(
            noteName: noteName, note: opened, hasVault: Vault.configured != nil,
            hasSummary: record.summaryProfile != nil, problems: problems, warnings: warnings, rebuild: rebuild
        )
        record.reprocessing = nil
        save(record)
        currentID = nil
        currentTitle = nil
        currentPhase = nil
        // After every completed Processing, Retry included, so the Hook can update what it sent.
        if problems.isEmpty, HookRunner.isInstalled, let vault = Vault.configured, let noteURL = record.noteURL {
            do {
                if let transcriptURL = try vault.findTranscript(takkuID: record.takkuID, expectedNote: noteURL) {
                    HookRunner.shared.run(note: noteURL, transcript: transcriptURL, vault: vault.root)
                }
            } catch {
                lastError = String(localized: "Hook not run: \(error.localizedDescription)")
                logger.error("Hook not run: \(error, privacy: .public)")
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
            ?? vault.createMeetingNote(takkuID: record.takkuID, startedAt: record.startedAt)
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
        let wantsTitle = vault.isInMeetingsFolder(noteURL) && VaultNaming.renamedNoteName(
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
        let rename = renameIfProvisional(noteURL, title: title, startedAt: record.startedAt, in: vault)
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
        _ noteURL: URL, title: String?, startedAt: Date, in vault: Vault
    ) -> (url: URL, follow: Bool) {
        guard let title, vault.isInMeetingsFolder(noteURL),
              let newName = VaultNaming.renamedNoteName(
                  current: noteURL.deletingPathExtension().lastPathComponent, startedAt: startedAt, title: title
              )
        else { return (noteURL, false) }
        // Read before the rename: afterwards Obsidian may already show another note.
        let wasShownInObsidian = vault.isShownInObsidian(noteURL) ?? true
        do {
            let renamed = try vault.rename(noteURL, to: newName)
            return (renamed, wasShownInObsidian && AppSettings.opensNotes)
        } catch {
            logger.error("Renaming the note failed: \(error, privacy: .public)")
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
        // No Profile chosen ("Transcript" in the menu): no Summary and no Template, only the Transcript.
        guard let profile else { return (.transcriptOnly, nil, nil) }
        // A Profile deleted after the Meeting started has lost its key in the Keychain too.
        guard isTestProfile || AppSettings.summaryProfiles.contains(where: { $0.id == profile.id }) else {
            return (.failed(reason: String(localized: "the Profile \"\(profile.displayName)\" was deleted: choose another one in the menu and Retry.")), nil, nil)
        }
        guard !transcript.paragraphs.isEmpty else {
            return (.failed(reason: String(localized: "there is no speech in the Recording.")), nil, nil)
        }
        let log = AppSettings.keepSummaryLog ? SummaryRequests(recorder: SummaryLog.Recorder(), profile: profile) : nil
        let started = ContinuousClock.now
        logger.notice("Summary started: \(transcript.paragraphs.count) paragraphs, model \(profile.model, privacy: .public)")
        do {
            let client = try ChatClient(profile: profile)
            let prompt = SummaryPrompt(
                template: template, personalNotes: personalNotes, transcript: transcript, meetingLanguage: language,
                vocabulary: vocabulary, userName: NSFullUserName(), participants: participants
            )
            let summary = try await Summarizer(
                client: client, maxContextTokens: profile.maxContextTokens, log: log?.recorder, onProgress: onProgress
            )
                .summarize(prompt)
            logger.notice("Summary written in \(secondsSince(started), privacy: .public)")
            let titleClient = log.map { client.recording(into: $0.recorder, as: .title) } ?? client
            // On the text alone: the Screenshots' names would reach the model.
            let reply = wantsTitle
                ? try? await titleClient.complete(MeetingTitle.request(summary: summary.text, language: prompt.summaryLanguage, vocabulary: vocabulary))
                : nil
            return (
                .written(text: summary.withScreenshots, template: template.name, provider: profile.displayName),
                reply.flatMap(MeetingTitle.clean), log
            )
        } catch {
            logger.error("Summary not generated after \(secondsSince(started), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return (.failed(reason: error.localizedDescription), nil, log)
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
            logger.error("Processing state not saved: \(error, privacy: .public)")
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

    /// Rebuilds `recording.json` of a Recording interrupted by a crash, without silently
    /// dropping a Track whose Segment list is damaged.
    private func recoverRecording(_ record: ProcessingRecord, in directory: URL) throws {
        try Recording.recover(fromFolder: directory, takkuID: record.takkuID, startedAt: record.startedAt)
    }

    /// Damaged Recording folders already shown in the menu by a previous cleanup.
    private static let reportedCleanupProblemsKey = "reportedCleanupProblems"

    /// Deletes the audio of expired Recordings (see `RecordingStorage.deleteAudio(olderThanDays:)`).
    /// A damaged folder is shown in the menu once, not at every launch and every day: it stays in
    /// the log and in Settings → Recordings → *Delete audio…*.
    func cleanUpExpiredRecordings() {
        let problems = RecordingStorage.deleteAudio(olderThanDays: AppSettings.retentionDays)
        for problem in problems { logger.error("Cleanup: \(problem, privacy: .public)") }
        let reported = Set(UserDefaults.standard.stringArray(forKey: Self.reportedCleanupProblemsKey) ?? [])
        UserDefaults.standard.set(problems, forKey: Self.reportedCleanupProblemsKey)
        let new = problems.filter { !reported.contains($0) }
        if !new.isEmpty { lastError = new.joined(separator: " ") }
        refreshRecent()
    }
}
