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
    /// with the transcription caches, the Screenshots (already in the Vault) and the `transcript.md` copy. Meetings still pending are
    /// kept. The manifests stay: the Meeting stays among the recent ones and Retry makes the
    /// Summary again from the Transcript in the Vault.
    static func deleteAudio(olderThanDays days: Int?) {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: MeetingRecorder.recordingsDirectory, includingPropertiesForKeys: nil
        )) ?? []
        let items = folders.compactMap { folder -> Retention.Item? in
            guard let takkuID = UUID(uuidString: folder.lastPathComponent) else { return nil }
            guard let record = try? ProcessingRecord.load(fromFolder: folder) else { return nil }
            return Retention.Item(takkuID: takkuID, startedAt: record.startedAt, status: record.status)
        }
        let kept = Set([Recording.fileName, ProcessingRecord.fileName] + Track.allCases.map(Segment.listFileName(for:)))
        for takkuID in Retention.expired(items, now: Date(), days: days) {
            let folder = MeetingProcessor.directory(for: takkuID)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where !kept.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
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
