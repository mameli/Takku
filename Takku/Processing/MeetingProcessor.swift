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
    struct RecentMeeting: Identifiable, Equatable {
        let id: UUID
        let title: String
        let status: ProcessingRecord.Status
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

    func meetingStopped(takkuID: UUID) {
        guard var record = recordingRecords.removeValue(forKey: takkuID) ?? record(takkuID) else { return }
        record.status = .queued
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
        guard let vault = Vault.configured,
              let note = vault.findMeetingNote(takkuID: takkuID, expected: record(takkuID)?.noteURL)
        else {
            lastError = String(localized: "Meeting note not found in the Vault.")
            return
        }
        Vault.openInObsidian(note)
    }

    /// In Obsidian like the notes; the copy in the Recording folder (no Vault) with the default app.
    func openLastTranscript() {
        guard let url = lastTranscriptURL else { return }
        if let vault = Vault.configured, vault.contains(url) {
            Vault.openInObsidian(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Retry, with the Template and Profile chosen in the menu now: they become the Meeting's.
    /// With the audio still there the whole Processing is redone (Segments already transcribed
    /// come from the cache); once the audio is deleted, only the Summary is made again from the
    /// Transcript in the Vault (a Regeneration). Only for concluded Meetings: one being recorded
    /// or already queued is left alone.
    func retry(_ takkuID: UUID, templateName: String, profile: ProviderProfile?) {
        guard var record = record(takkuID) else { return }
        record.templateName = templateName
        record.summaryProfile = profile
        let hasAudio = RecordingStorage.hasAudio(Self.directory(for: takkuID))
        guard (try? hasAudio ? record.queueForRetry() : record.beginRegeneration()) != nil else { return }
        // Once accepted and before enqueueing, so the count leaves this Retry out.
        logger.notice("""
            Retry \(takkuID, privacy: .public): \(hasAudio ? "full Processing" : "Regeneration", privacy: .public), \
            Template \(templateName, privacy: .public), model \(profile?.model ?? "none", privacy: .public), \
            \(self.pendingCount) ahead in the queue
            """)
        save(record)
        if hasAudio {
            enqueueProcessing(record)
        } else {
            enqueue { await self.runRegeneration(record) }
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

        // Read once per Processing: a change counts from the next Meeting, or from a Retry.
        let vocabulary = TakkuFolder.vocabulary()
        var problems: [String] = []
        // An unreadable Segment (e.g. the one open during a crash) leaves a gap in the
        // Transcript but does not prevent the Summary: it is a warning, not a failure.
        var warnings: [String] = []
        let finished: MeetingTranscription.Finished?
        do {
            finished = try await transcription.finish(recording, in: directory, vocabulary: vocabulary)
            if let failedSegments = finished?.failedSegments, !failedSegments.isEmpty {
                warnings.append(String(localized: "Incomplete transcript: \(failedSegments.joined(separator: "; "))"))
            }
            if let speakersProblem = finished?.speakersProblem {
                warnings.append(String(localized: "Speakers not told apart: \(speakersProblem)"))
            }
            lastTranscriptURL = finished?.url
            logger.notice("Transcript ready after \(secondsSince(started), privacy: .public)")
        } catch {
            finished = nil
            problems.append(String(localized: "Transcription failed: \(error.localizedDescription)"))
        }

        if let vault = Vault.configured {
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
            warnings.append(String(localized: "No Vault configured: no Summary, the Transcript is only in the Recording folder."))
        }
        finish(&record, problems: problems, warnings: warnings, started: started)
    }

    private func runRegeneration(_ queued: ProcessingRecord) async {
        var record = queued
        let takkuID = record.takkuID
        let started = ContinuousClock.now
        logger.notice("Regeneration \(takkuID, privacy: .public) started")
        guard let vault = Vault.configured,
              var noteURL = vault.findMeetingNote(takkuID: takkuID, expected: record.noteURL),
              let transcriptURL = vault.findTranscript(takkuID: takkuID),
              let transcriptFile = try? String(contentsOf: transcriptURL, encoding: .utf8)
        else {
            finish(&record, problems: [String(localized: "Retry not possible: the audio is deleted and the Meeting note or Transcript is not in the Vault.")], warnings: [], started: started)
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
                if let relabeled = Transcript.relabeling(vaultFile: transcriptFile, names: speakerNames) {
                    try relabeled.write(to: transcriptURL, atomically: true, encoding: .utf8)
                }
                try vault.update(noteURL) {
                    $0.recordRegeneration(
                        takkuID: takkuID, transcriptName: transcriptURL.deletingPathExtension().lastPathComponent, summary: summary
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

    private func finish(_ record: inout ProcessingRecord, problems: [String], warnings: [String], started: ContinuousClock.Instant) {
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
        Notifications.shared.processingFinished(
            noteName: noteName, note: record.noteURL, hasVault: Vault.configured != nil,
            hasSummary: record.summaryProfile != nil, problems: problems, warnings: warnings
        )
        save(record)
        // After every completed Processing, Retry included, so the Hook can update what it sent.
        if problems.isEmpty, HookRunner.isInstalled, let vault = Vault.configured, let noteURL = record.noteURL,
           let transcriptURL = vault.findTranscript(takkuID: record.takkuID) {
            HookRunner.shared.run(note: noteURL, transcript: transcriptURL, vault: vault.root)
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

        return try await writeSummary(
            finished.transcript, language: finished.language, into: noteURL, record: record, vault: vault,
            vocabulary: vocabulary
        ) { noteURL, summary, speakerNames in
            // Written after the rename: a new Transcript is named after the note's final name.
            let transcriptURL = try vault.writeTranscript(
                finished.transcript.naming(speakerNames),
                takkuID: record.takkuID,
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
                    summary: summary
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
        let (summary, title) = await summarize(
            transcript.naming(speakerNames), language: language, personalNotes: note.personalNotes,
            participants: note.participants, wantsTitle: wantsTitle,
            template: TakkuFolder.template(named: record.templateName), profile: record.summaryProfile, vocabulary: vocabulary
        )
        let rename = renameIfProvisional(noteURL, title: title, startedAt: record.startedAt, in: vault)
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
            return (renamed, wasShownInObsidian && AppSettings.openInObsidian)
        } catch {
            logger.error("Renaming the note failed: \(error, privacy: .public)")
            return (noteURL, false)
        }
    }

    /// Summary and title for the rename. A missing title is not an error: the note keeps its
    /// provisional name.
    private func summarize(
        _ transcript: Transcript, language: String?, personalNotes: String, participants: [String], wantsTitle: Bool,
        template: Template, profile: ProviderProfile?, vocabulary: Vocabulary
    ) async -> (MeetingNote.SummaryOutcome, String?) {
        var profile = profile
        var isTestProfile = false
        #if DEBUG
        if let testProfile = AppSettings.testSummaryProfile {
            profile = testProfile
            isTestProfile = true
        }
        #endif
        // No Profile chosen ("Transcript" in the menu): no Summary and no Template, only the Transcript.
        guard let profile else { return (.transcriptOnly, nil) }
        // A Profile deleted after the Meeting started has lost its key in the Keychain too.
        guard isTestProfile || AppSettings.summaryProfiles.contains(where: { $0.id == profile.id }) else {
            return (.failed(reason: String(localized: "the Profile \"\(profile.displayName)\" was deleted: choose another one in the menu and Retry.")), nil)
        }
        guard !transcript.paragraphs.isEmpty else {
            return (.failed(reason: String(localized: "there is no speech in the Recording.")), nil)
        }
        let started = ContinuousClock.now
        logger.notice("Summary started: \(transcript.paragraphs.count) paragraphs, model \(profile.model, privacy: .public)")
        do {
            let client = try ChatClient(profile: profile)
            let prompt = SummaryPrompt(
                template: template, personalNotes: personalNotes, transcript: transcript, meetingLanguage: language,
                vocabulary: vocabulary, userName: NSFullUserName(), participants: participants
            )
            let text = try await Summarizer(client: client, maxContextTokens: profile.maxContextTokens).summarize(prompt)
            logger.notice("Summary written in \(secondsSince(started), privacy: .public)")
            let reply = wantsTitle
                ? try? await client.complete(MeetingTitle.request(summary: text, language: prompt.summaryLanguage, vocabulary: vocabulary))
                : nil
            return (.written(text: text, template: template.name, provider: profile.displayName), reply.flatMap(MeetingTitle.clean))
        } catch {
            logger.error("Summary not generated after \(secondsSince(started), privacy: .public): \(error, privacy: .public)")
            return (.failed(reason: error.localizedDescription), nil)
        }
    }

    // MARK: - State on disk

    private func record(_ takkuID: UUID) -> ProcessingRecord? {
        try? ProcessingRecord.load(fromFolder: Self.directory(for: takkuID))
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
        recordingFolders().compactMap { try? ProcessingRecord.load(fromFolder: $0) }
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
        for record in allRecords().sorted(by: { $0.startedAt > $1.startedAt }) where meetings.count < 5 {
            var note = record.noteURL
            if vault != nil, let expected = record.noteURL, !record.status.isPending,
               !FileManager.default.fileExists(atPath: expected.path(percentEncoded: false)) {
                guard let moved = notesByTakkuID[record.takkuID] else { continue }
                note = moved
            }
            let title = note?.deletingPathExtension().lastPathComponent
                ?? record.startedAt.formatted(date: .abbreviated, time: .shortened)
            meetings.append(RecentMeeting(id: record.takkuID, title: title, status: record.status))
        }
        // Unchanged most of the time: assigning would rebuild the menu anyway.
        if meetings != recent { recent = meetings }
    }

    /// Rebuilds `recording.json` of a Recording interrupted by a crash from the Segment
    /// lists; the end is the last write of a Segment.
    private func recoverRecording(_ record: ProcessingRecord, in directory: URL) throws {
        let segments = Track.allCases.flatMap { track -> [Segment] in
            let url = directory.appending(path: Segment.listFileName(for: track))
            return (try? JSONDecoder().decode([Segment].self, from: Data(contentsOf: url))) ?? []
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )
        let lastWrite = files
            .filter { $0.pathExtension == "m4a" }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max() ?? record.startedAt
        try Recording.recovered(takkuID: record.takkuID, startedAt: record.startedAt, segments: segments, lastWrite: lastWrite)
            .save(inFolder: directory)
    }

    /// Deletes the audio of expired Recordings (see `RecordingStorage.deleteAudio(olderThanDays:)`).
    func cleanUpExpiredRecordings() {
        RecordingStorage.deleteAudio(olderThanDays: AppSettings.retentionDays)
        refreshRecent()
    }
}
