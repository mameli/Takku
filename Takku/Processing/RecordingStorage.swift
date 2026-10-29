import Foundation
import TakkuCore

/// The audio kept in the Recording folders: how much there is, and deleting it when it expires
/// or when the user asks from Settings.
@MainActor
enum RecordingStorage {
    /// Whether the Recording folder still has its audio (it is deleted after the retention days).
    static func hasAudio(_ directory: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.contains { $0.pathExtension == "m4a" }
    }

    /// Deletes the audio files of concluded Recordings older than `days` days (0: all of them; `nil`: none),
    /// with the transcription caches and the Screenshots already in the Vault. Meetings still
    /// pending are kept. The manifests stay: the Meeting stays among the recent ones and Retry
    /// makes the Summary again from the Transcript in the Vault. The local `transcript.md` is
    /// deleted too, unless it is the only copy left (Meetings processed without a Vault).
    /// Returns damaged state that made cleanup skip a Recording; its audio is always preserved.
    @discardableResult
    static func deleteAudio(olderThanDays days: Int?) -> [String] {
        var problems: [String] = []
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: MeetingRecorder.recordingsDirectory, includingPropertiesForKeys: nil
        )) ?? []
        let items = folders.compactMap { folder -> Retention.Item? in
            guard let takkuID = UUID(uuidString: folder.lastPathComponent) else { return nil }
            do {
                let record = try ProcessingRecord.load(fromFolder: folder)
                guard record.takkuID == takkuID else {
                    problems.append(String(localized: "Processing state belongs to another Meeting in \(folder.lastPathComponent). Audio kept."))
                    return nil
                }
                // An imported file keeps its original date in the Meeting note and calendar, but its
                // local copy must get a full retention period from when it was imported.
                let retainedSince = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? record.startedAt
                return Retention.Item(takkuID: takkuID, startedAt: retainedSince, status: record.status)
            } catch {
                let manifest = folder.appending(path: ProcessingRecord.fileName)
                let problem = if FileManager.default.fileExists(atPath: manifest.path(percentEncoded: false)) {
                    String(localized: "Processing state is unreadable in \(folder.lastPathComponent): \(error.localizedDescription) Audio kept.")
                } else {
                    String(localized: "Processing state is missing in \(folder.lastPathComponent). Audio kept.")
                }
                problems.append(problem)
                return nil
            }
        }
        let manifests = Set([Recording.fileName, ProcessingRecord.fileName] + Track.allCases.map(Segment.listFileName(for:)))
        let vault = Vault.configured
        for takkuID in Retention.expired(items, now: Date(), days: days) {
            let folder = MeetingProcessor.directory(for: takkuID)
            do {
                let recording = try Recording.load(fromFolder: folder)
                guard recording.meetingID == takkuID else {
                    problems.append(String(localized: "Recording manifest belongs to another Meeting in \(folder.lastPathComponent). Audio kept."))
                    continue
                }
            } catch {
                problems.append(String(localized: "Recording manifest is unreadable in \(folder.lastPathComponent): \(error.localizedDescription) Audio kept."))
                continue
            }
            var kept = manifests
            var hasVaultTranscript = false
            if let vault {
                do {
                    let expectedNote = (try? ProcessingRecord.load(fromFolder: folder))?.noteURL ?? nil
                    hasVaultTranscript = try vault.findTranscript(takkuID: takkuID, expectedNote: expectedNote) != nil
                } catch {
                    // An ambiguous Vault copy must not make Takku delete the only known-safe one.
                    problems.append(error.localizedDescription)
                }
            }
            if !hasVaultTranscript { kept.insert(Transcript.recordingCopyFileName) }
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where !kept.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        return problems
    }

    /// Bytes of audio kept, shown in Settings.
    static func audioSize() -> Int64 {
        let enumerator = FileManager.default.enumerator(
            at: MeetingRecorder.recordingsDirectory, includingPropertiesForKeys: [.fileSizeKey]
        )
        var total: Int64 = 0
        while let file = enumerator?.nextObject() as? URL {
            if file.pathExtension == "m4a" {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }
}
