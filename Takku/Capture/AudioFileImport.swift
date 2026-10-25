import AVFoundation
import TakkuCore

/// An audio or video file recorded elsewhere (a voice memo, a lecture, a call recorded by another
/// app) turned into the Recording of a new Meeting; of a video only the sound is read. Its audio becomes the Others Track, in Segments
/// like a recorded one, so Transcript, Speakers, Summary and Retry work as for a call; there is
/// no Me Track, so the user is one of the Speakers. The file itself is only read.
enum AudioFileImport {
    struct Imported {
        let directory: URL
        let recording: Recording
        /// The start was read from the file's own metadata, when it was recorded. Otherwise it is
        /// the file's creation date, which can be when it was copied or downloaded.
        let isRecordingDate: Bool
    }

    /// Frames read at a time: about a second of audio.
    private static let framesPerRead: AVAudioFrameCount = 48_000

    static func run(_ url: URL, into recordingsDirectory: URL, segmentDuration: TimeInterval) async throws -> Imported {
        let name = url.lastPathComponent
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw CaptureError.unreadableFile(name)
        }
        guard file.length > 0 else { throw CaptureError.noAudio(name) }
        let sampleRate = file.processingFormat.sampleRate
        let (startedAt, isRecordingDate) = await startDate(of: url)

        let meetingID = UUID()
        let directory = recordingsDirectory.appending(path: meetingID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            // The writer places each buffer by its host time: here, its position in the file.
            let writer = SegmentedTrackWriter(
                track: .others, directory: directory, meetingStartHostTime: 0,
                segmentDuration: segmentDuration, onSegmentClosed: { _, _ in }
            )
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: framesPerRead) else {
                throw CaptureError.unsupportedFormat(file.processingFormat.description)
            }
            while file.framePosition < file.length {
                let position = file.framePosition
                try file.read(into: buffer, frameCount: framesPerRead)
                guard buffer.frameLength > 0 else { break }
                writer.write(buffer, hostTime: AVAudioTime.hostTime(forSeconds: Double(position) / sampleRate))
            }
            let outcome = writer.finish()
            if let error = outcome.error { throw error }
            let recording = Recording(
                meetingID: meetingID, startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(Double(file.length) / sampleRate), segments: outcome.segments
            )
            try recording.save(inFolder: directory)
            return Imported(directory: directory, recording: recording, isRecordingDate: isRecordingDate)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// When the file was recorded if its metadata says so (Voice Memos and most recorders write
    /// it), otherwise when the file was created.
    private static func startDate(of url: URL) async -> (Date, isRecordingDate: Bool) {
        if let item = try? await AVURLAsset(url: url).load(.creationDate),
           let date = try? await item.load(.dateValue) {
            return (date, true)
        }
        let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        return (created ?? Date(), false)
    }
}
