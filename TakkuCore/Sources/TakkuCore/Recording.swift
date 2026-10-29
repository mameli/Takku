import Foundation

/// The audio of a Meeting: when it started and the Segments each Track is saved in.
public struct Recording: Codable, Equatable, Sendable {
    public let meetingID: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let segments: [Segment]

    public init(meetingID: UUID, startedAt: Date, endedAt: Date, segments: [Segment]) {
        self.meetingID = meetingID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.segments = segments
    }

    /// The manifest in the Recording folder.
    public static let fileName = "recording.json"

    /// Segment sample rate: mono 16 kHz, what Whisper expects.
    public static let sampleRate: Double = 16_000

    /// Reads the manifest of a Recording folder.
    public static func load(fromFolder folder: URL) throws -> Recording {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Recording.self, from: Data(contentsOf: folder.appending(path: fileName)))
    }

    public func save(inFolder folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: folder.appending(path: Self.fileName), options: .atomic)
    }

    /// A Recording interrupted by a crash, rebuilt from the Segment lists each Track saves
    /// whenever a Segment opens. The end is the last write to disk.
    public static func recovered(takkuID: UUID, startedAt: Date, segments: [Segment], lastWrite: Date) -> Recording {
        let ordered = Track.allCases.flatMap { track in
            segments.filter { $0.track == track }.sorted { $0.index < $1.index }
        }
        return Recording(meetingID: takkuID, startedAt: startedAt, endedAt: lastWrite, segments: ordered)
    }

    /// Recovers and saves an interrupted Recording, preferring an existing valid manifest. A Track
    /// without a Segment list is legitimately empty only when it has no audio. Every list is read
    /// before the manifest is written, so damaged state can never be replaced by a partial Track.
    @discardableResult
    public static func recover(fromFolder folder: URL, takkuID: UUID, startedAt: Date) throws -> Recording {
        if let existing = try? load(fromFolder: folder), existing.meetingID == takkuID { return existing }
        let files = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        )
        var segments: [Segment] = []
        for track in Track.allCases {
            let url = folder.appending(path: Segment.listFileName(for: track))
            do {
                segments += try JSONDecoder().decode([Segment].self, from: Data(contentsOf: url))
            } catch {
                let hasList = FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
                let hasAudio = files.contains {
                    $0.pathExtension == "m4a" && $0.lastPathComponent.hasPrefix(track.rawValue + "-")
                }
                if !hasList, !hasAudio { continue }
                if !hasList { throw RecordingRecoveryError.missingSegmentList(url.lastPathComponent) }
                throw RecordingRecoveryError.unreadableSegmentList(file: url.lastPathComponent, reason: error.localizedDescription)
            }
        }
        let lastWrite = files
            .filter { $0.pathExtension == "m4a" }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max() ?? startedAt
        let recording = recovered(takkuID: takkuID, startedAt: startedAt, segments: segments, lastWrite: lastWrite)
        try recording.save(inFolder: folder)
        return recording
    }
}

public enum RecordingRecoveryError: LocalizedError, Equatable {
    case missingSegmentList(String)
    case unreadableSegmentList(file: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .missingSegmentList(let file):
            String(localized: "Cannot recover the Recording: \(file) is missing although its Track has audio.")
        case .unreadableSegmentList(let file, let reason):
            String(localized: "Cannot recover the Recording: \(file) is unreadable (\(reason)).")
        }
    }
}
