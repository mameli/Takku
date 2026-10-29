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
    /// Folders already cleaned are skipped without reading anything else: the manifests stay
    /// forever, so the Vault is read only for those that still have a local Transcript.
    /// Returns damaged state that made cleanup skip a Recording; its audio is always preserved.
    @discardableResult
    static func deleteAudio(olderThanDays days: Int?) -> [String] {
        guard days != nil else { return [] }
        var problems: [String] = []
        let manifests = Set([Recording.fileName, ProcessingRecord.fileName] + Track.allCases.map(Segment.listFileName(for:)))
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: MeetingRecorder.recordingsDirectory, includingPropertiesForKeys: nil
        )) ?? []
        var filesByID: [UUID: [URL]] = [:]
        let items = folders.compactMap { folder -> Retention.Item? in
            guard let takkuID = UUID(uuidString: folder.lastPathComponent) else { return nil }
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            guard files.contains(where: { !manifests.contains($0.lastPathComponent) }) else { return nil }
            filesByID[takkuID] = files
            do {
                let record = try ProcessingRecord.load(fromFolder: folder)
                guard record.takkuID == takkuID else {
                    problems.append(String(localized: "Processing state belongs to another Meeting in \(folder.lastPathComponent). Audio kept."))
                    return nil
                }
                // An imported file keeps its original date in the Meeting note and calendar, but its
                // local copy must get a full retention period from when it was imported.
                let retainedSince = record.importedAt
                    ?? (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate)
                    ?? record.startedAt
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
        let vault = Vault.configured
        // Read once, and only if an expired folder still has its local Transcript.
        var vaultTranscripts: [UUID: [URL]]?
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
            let files = filesByID[takkuID] ?? []
            var kept = manifests
            if files.contains(where: { $0.lastPathComponent == Transcript.recordingCopyFileName }) {
                var hasVaultTranscript = false
                if let vault {
                    if vaultTranscripts == nil { vaultTranscripts = vault.transcriptsByTakkuID() }
                    let matches = vaultTranscripts?[takkuID] ?? []
                    if matches.count == 1 {
                        hasVaultTranscript = true
                    } else if matches.count > 1 {
                        do {
                            // Sync copies: the note's Transcript link may still tell which one is its own.
                            let expectedNote = (try? ProcessingRecord.load(fromFolder: folder))?.noteURL ?? nil
                            hasVaultTranscript = try vault.findTranscript(takkuID: takkuID, expectedNote: expectedNote) != nil
                        } catch {
                            // An ambiguous Vault copy must not make Takku delete the only known-safe one.
                            problems.append(error.localizedDescription)
                        }
                    }
                }
                if !hasVaultTranscript { kept.insert(Transcript.recordingCopyFileName) }
            }
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
