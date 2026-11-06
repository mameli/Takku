import Foundation
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "summary")

/// The Summary log on disk (`~/.takku/summary-log/`): writing an entry within the limit, how
/// much there is, and deleting it from Settings.
@MainActor
enum SummaryLogStorage {
    /// Writes the entry and deletes the oldest ones past `SummaryLog.limitBytes`. A failure is
    /// only logged: the Summary does not depend on it.
    static func write(_ entry: SummaryLog.Entry) {
        let folder = TakkuFolder.summaryLogFolder
        do {
            try TakkuFolder.ensureFolder(folder)
            let taken = Set(entries().map { $0.url.deletingPathExtension().lastPathComponent })
            let name = VaultNaming.available(entry.fileName(), taken: taken)
            try entry.json().write(to: folder.appending(path: name + ".json"), options: .atomic)
        } catch {
            logger.error("Summary log entry not written: \(error.logCode, privacy: .public) \(error, privacy: .private)")
            return
        }
        for url in SummaryLog.overLimit(entries()) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Bytes of the Summary log, shown in Settings.
    static func size() -> Int64 {
        entries().reduce(0) { $0 + Int64($1.bytes) }
    }

    /// Deletes every entry: it cannot be undone.
    static func deleteAll() {
        for entry in entries() {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    private static func entries() -> [SummaryLog.StoredEntry] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: TakkuFolder.summaryLogFolder, includingPropertiesForKeys: Array(keys)
        )) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return SummaryLog.StoredEntry(url: url, bytes: values.fileSize ?? 0, writtenAt: values.creationDate ?? .distantPast)
        }
    }
}
