import Foundation
import Testing
import TakkuCore

@Suite("Processing queue")
struct ProcessingRecordTests {
    let start = Date(timeIntervalSince1970: 1_791_117_000)

    func record(_ status: ProcessingRecord.Status, minutesAfterStart minutes: Double = 0) -> ProcessingRecord {
        ProcessingRecord(
            takkuID: UUID(), startedAt: start.addingTimeInterval(minutes * 60),
            status: status, templateName: "Notes", summaryProfile: nil, noteURL: nil
        )
    }

    @Test("after a restart, Meetings queued, in progress or interrupted while recording resume, oldest first")
    func resumeAfterRestart() {
        let completed = record(.completed, minutesAfterStart: 0)
        let failed = record(.failed(reason: "401"), minutesAfterStart: 10)
        let processing = record(.processing, minutesAfterStart: 30)
        let queued = record(.queued, minutesAfterStart: 20)
        let interrupted = record(.recording, minutesAfterStart: 40)

        let plan = ProcessingRecord.afterRestart([interrupted, completed, processing, failed, queued])

        #expect(plan.toProcess.map(\.takkuID) == [queued.takkuID, processing.takkuID, interrupted.takkuID])
        #expect(plan.toSave.isEmpty)
    }

    @Test("the state saved on disk reads back identical, including a failure reason")
    func persistence() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var saved = record(.failed(reason: "The provider answered with error 401"))
        saved.summaryProfile = ProviderProfile(name: "Mistral UE", baseURL: "https://api.mistral.ai/v1", model: "m", maxContextTokens: 32_000)
        saved.noteURL = URL(filePath: "/Vault/Meetings/2026-10-04 1430 - Meeting.md")
        saved.reprocessing = .fromScratch
        saved.importedAt = start.addingTimeInterval(3_600)
        saved.importWarnings = ["Unreadable audio skipped from 1.000 s to 1.064 s."]
        saved.statusBeforeRetry = .completed

        try saved.save(inFolder: directory)

        #expect(try ProcessingRecord.load(fromFolder: directory) == saved)
    }

    @Test("a record written before cache and import metadata existed keeps safe defaults")
    func legacyCacheFlag() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = record(.completed)
        try saved.save(inFolder: directory)
        let url = directory.appending(path: ProcessingRecord.fileName)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object.removeValue(forKey: "reprocessing")
        object.removeValue(forKey: "importedAt")
        object.removeValue(forKey: "importWarnings")
        object.removeValue(forKey: "statusBeforeRetry")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(ProcessingRecord.self, from: data)
        #expect(decoded.reprocessing == nil)
        #expect(!decoded.ignoresTranscriptionCache)
        #expect(decoded.importedAt == nil)
        #expect(decoded.importWarnings == nil)
        #expect(decoded.recentAt == decoded.startedAt)
    }

    @Test("only a Reprocess from scratch ignores the transcription and Speaker caches")
    func reprocessingCache() {
        var reprocessed = record(.queued)

        reprocessed.reprocessing = .reusingCache
        #expect(!reprocessed.ignoresTranscriptionCache)
        reprocessed.reprocessing = .fromScratch
        #expect(reprocessed.ignoresTranscriptionCache)
    }

    @Test("an old Recording imported now is more recent than a newer recorded Meeting")
    func importedRecency() {
        var imported = record(.completed)
        imported.importedAt = start.addingTimeInterval(3_600)
        let recordedLater = record(.completed, minutesAfterStart: 30)

        #expect([recordedLater, imported].sorted { $0.recentAt > $1.recentAt }.map(\.takkuID) == [imported.takkuID, recordedLater.takkuID])
    }

    @Test("a Recording interrupted by a crash is rebuilt from the saved Segment lists")
    func recoveredRecording() {
        let id = UUID()
        let end = start.addingTimeInterval(612)
        let others = [Segment(track: .others, index: 1, start: 300.1), Segment(track: .others, index: 0, start: 0.1)]
        let me = [Segment(track: .me, index: 0, start: 0.2), Segment(track: .me, index: 1, start: 300.2)]

        let recording = Recording.recovered(takkuID: id, startedAt: start, segments: others + me, lastWrite: end)

        #expect(recording.meetingID == id)
        #expect(recording.endedAt == end)
        #expect(recording.segments.map(\.fileName) == ["me-000.m4a", "me-001.m4a", "others-000.m4a", "others-001.m4a"])
    }

    @Test("after a restart an interrupted Regeneration does not become full Processing: the Meeting goes back to completed")
    func interruptedRegeneration() {
        let regenerating = record(.regenerating, minutesAfterStart: 5)
        let queued = record(.queued, minutesAfterStart: 10)

        let plan = ProcessingRecord.afterRestart([regenerating, queued])

        #expect(plan.toProcess.map(\.takkuID) == [queued.takkuID])
        #expect(plan.toSave.map(\.takkuID) == [regenerating.takkuID])
        #expect(plan.toSave.first?.status == .completed)
    }

    @Test("after a restart an interrupted Regeneration of a failed Meeting goes back to failed, with its reason")
    func interruptedRegenerationOfFailed() throws {
        var meeting = record(.failed(reason: "401"))
        try meeting.beginRegeneration()

        let plan = ProcessingRecord.afterRestart([meeting])

        #expect(plan.toSave.first?.status == .failed(reason: "401"))
        #expect(plan.toSave.first?.statusBeforeRetry == nil)
    }

    @Test("stopping a Retry or a Regeneration gives the Meeting back as it was, queued or running", arguments: [
        ProcessingRecord.Status.completed, .failed(reason: "Timeout"),
    ])
    func stopRetry(before: ProcessingRecord.Status) throws {
        var queued = record(before)
        try queued.queueForRetry()
        queued.reprocessing = .fromScratch
        var running = record(before)
        try running.queueForRetry()
        running.status = .processing
        var regenerating = record(before)
        try regenerating.beginRegeneration()

        for var meeting in [queued, running, regenerating] {
            try meeting.stop(reason: "Stopped")
            #expect(meeting.status == before)
            #expect(meeting.statusBeforeRetry == nil)
            #expect(meeting.reprocessing == nil)
            #expect(ProcessingRecord.afterRestart([meeting]).toProcess.isEmpty)
        }
    }

    @Test("stopping a Meeting never processed makes it failed with the reason, so it can be retried and is not resumed")
    func stopFirstProcessing() throws {
        for status in [ProcessingRecord.Status.queued, .processing] {
            var meeting = record(status)

            try meeting.stop(reason: "Stopped")

            #expect(meeting.status == .failed(reason: "Stopped"))
            #expect(meeting.status.canRetry)
            #expect(ProcessingRecord.afterRestart([meeting]).toProcess.isEmpty)
        }
    }

    @Test("only a queued or running Processing can be stopped", arguments: [
        ProcessingRecord.Status.recording, .completed, .failed(reason: "401"),
    ])
    func stopNotAllowed(status: ProcessingRecord.Status) {
        var meeting = record(status)

        #expect(throws: ProcessingRecord.InvalidTransition.self) { try meeting.stop(reason: "Stopped") }
        #expect(meeting.status == status)
    }

    @Test("Retry and Regenerate are allowed only for completed or failed Meetings", arguments: [
        (ProcessingRecord.Status.completed, true),
        (.failed(reason: "401"), true),
        (.recording, false),
        (.queued, false),
        (.processing, false),
        (.regenerating, false),
    ])
    func retryAllowed(status: ProcessingRecord.Status, allowed: Bool) {
        var retried = record(status)
        var regenerated = record(status)

        #expect(status.canRetry == allowed)
        #expect(((try? retried.queueForRetry()) != nil) == allowed)
        #expect(((try? regenerated.beginRegeneration()) != nil) == allowed)
        if allowed {
            #expect(retried.status == .queued)
            #expect(regenerated.status == .regenerating)
        } else {
            #expect(retried.status == status)
        }
    }

    @Test("Retry keeps a failed Meeting's Template and takes the menu's for a completed one", arguments: [
        (ProcessingRecord.Status.failed(reason: "Timeout"), "Standup"),
        (.completed, "Notes"),
    ])
    func retryTemplate(status: ProcessingRecord.Status, expected: String) {
        var meeting = record(status)
        meeting.templateName = "Standup"

        #expect(meeting.retryTemplate(chosen: "Notes") == expected)
    }
}
