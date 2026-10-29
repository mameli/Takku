import Foundation
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "processing")

/// The voices remembered for voice recognition, in `voices.json` next to the Recordings and
/// readable by the user only. Never in the Vault or in `~/.takku`, which may be synced elsewhere.
@MainActor
enum VoiceStorage {
    static var url: URL {
        #if DEBUG
        // Automated tests: test voices stay outside the real file.
        if let path = UserDefaults.standard.string(forKey: "testVoicesFile") {
            return URL(filePath: path)
        }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Takku/voices.json")
    }

    /// An unreadable file counts as no voices: suggestions are only a help.
    static func load() -> VoiceLibrary {
        guard let data = try? Data(contentsOf: url) else { return VoiceLibrary() }
        do {
            return try JSONDecoder().decode(VoiceLibrary.self, from: data)
        } catch {
            logger.error("Voices not read: \(error, privacy: .public)")
            return VoiceLibrary()
        }
    }

    static func save(_ library: VoiceLibrary) throws {
        guard !library.voices.isEmpty else {
            try deleteAll()
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(library).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }

    /// Deletes every voice: it cannot be undone.
    static func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
