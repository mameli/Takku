import Foundation
import Testing
import TakkuCore

@Suite("Recording recovery")
struct RecordingRecoveryTests {
    private let id = UUID()
    private let start = Date(timeIntervalSince1970: 1_791_117_000)

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a valid Recording manifest is preferred to damaged recovery files")
    func existingManifestPreferred() throws {
        let directory = try folder()
        let recording = Recording(meetingID: id, startedAt: start, endedAt: start.addingTimeInterval(60), segments: [])
        try recording.save(inFolder: directory)
        try Data("not JSON".utf8).write(to: directory.appending(path: Segment.listFileName(for: .me)))

        #expect(try Recording.recover(fromFolder: directory, takkuID: id, startedAt: start) == recording)
    }

    @Test("a valid manifest for another Meeting is not reused")
    func mismatchedManifest() throws {
        let directory = try folder()
        let other = Recording(meetingID: UUID(), startedAt: start, endedAt: start, segments: [])
        try other.save(inFolder: directory)

        let recovered = try Recording.recover(fromFolder: directory, takkuID: id, startedAt: start)

        #expect(recovered.meetingID == id)
        #expect(try Recording.load(fromFolder: directory).meetingID == id)
    }

    @Test("a missing Segment list is an empty Track only when that Track has no audio")
    func missingLists() throws {
        let emptyDirectory = try folder()
        let empty = try Recording.recover(fromFolder: emptyDirectory, takkuID: id, startedAt: start)
        #expect(empty.segments.isEmpty)
        #expect(FileManager.default.fileExists(atPath: emptyDirectory.appending(path: Recording.fileName).path(percentEncoded: false)))

        let damagedDirectory = try folder()
        try Data().write(to: damagedDirectory.appending(path: "others-000.m4a"))

        #expect(throws: RecordingRecoveryError.missingSegmentList("others-segments.json")) {
            try Recording.recover(fromFolder: damagedDirectory, takkuID: id, startedAt: start)
        }
        #expect(!FileManager.default.fileExists(atPath: damagedDirectory.appending(path: Recording.fileName).path(percentEncoded: false)))
    }

    @Test("a corrupt Segment list stops recovery instead of writing a partial Recording")
    func corruptList() throws {
        let directory = try folder()
        try Data("not JSON".utf8).write(to: directory.appending(path: Segment.listFileName(for: .me)))
        let others = [Segment(track: .others, index: 0, start: 0)]
        try JSONEncoder().encode(others).write(to: directory.appending(path: Segment.listFileName(for: .others)))

        #expect(throws: RecordingRecoveryError.self) {
            try Recording.recover(fromFolder: directory, takkuID: id, startedAt: start)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: Recording.fileName).path(percentEncoded: false)))
    }
}
