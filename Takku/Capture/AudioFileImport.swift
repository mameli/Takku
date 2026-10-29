import AVFoundation
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "import")

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
        /// Recovered read errors that left actual gaps in the source audio.
        let warnings: [String]
    }

    /// Frames read at a time: about a second of audio.
    private static let framesPerRead: AVAudioFrameCount = 48_000
    /// Frames read at a time after a read error: one AAC packet, the smallest stretch skipped.
    private static let framesPerCarefulRead: AVAudioFrameCount = 1024

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
            // macOS's decoder can fail in the middle of a file that other players read (seen on an
            // AAC written by ffmpeg): the stretch is read again a packet at a time, which after the
            // seek often works, and only the packets still unreadable are skipped. The writer fills
            // what is skipped with silence.
            var carefulUntil: AVAudioFramePosition = 0
            var skipped: [Range<AVAudioFramePosition>] = []
            var firstError: Error?
            while file.framePosition < file.length {
                let position = file.framePosition
                let isCareful = position < carefulUntil
                do {
                    try file.read(into: buffer, frameCount: isCareful ? framesPerCarefulRead : framesPerRead)
                } catch {
                    firstError = firstError ?? error
                    if isCareful {
                        let end = min(position + AVAudioFramePosition(framesPerCarefulRead), file.length)
                        if let last = skipped.last, last.upperBound == position {
                            skipped[skipped.count - 1] = last.lowerBound..<end
                        } else {
                            skipped.append(position..<end)
                        }
                        file.framePosition = end
                    } else {
                        carefulUntil = position + AVAudioFramePosition(framesPerRead)
                        file.framePosition = position
                    }
                    continue
                }
                guard buffer.frameLength > 0 else { break }
                writer.write(buffer, hostTime: AVAudioTime.hostTime(forSeconds: Double(position) / sampleRate))
            }
            let outcome = writer.finish()
            if let error = outcome.error { throw error }
            if outcome.segments.isEmpty, let firstError { throw firstError }
            var warnings: [String] = []
            for stretch in skipped {
                let start = Double(stretch.lowerBound) / sampleRate, end = Double(stretch.upperBound) / sampleRate
                logger.warning("Skipped unreadable audio in \(name, privacy: .public) from \(start, format: .fixed(precision: 3)) s to \(end, format: .fixed(precision: 3)) s")
                warnings.append(String(localized: "Unreadable audio skipped from \(String(format: "%.3f", start)) s to \(String(format: "%.3f", end)) s; the Transcript and Summary may be incomplete."))
            }
            if let firstError {
                logger.notice("Read errors in \(name, privacy: .public), stretches skipped: \(skipped.count); the first error: \(firstError, privacy: .public)")
            }
            let recording = Recording(
                meetingID: meetingID, startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(Double(file.length) / sampleRate), segments: outcome.segments
            )
            try recording.save(inFolder: directory)
            return Imported(directory: directory, recording: recording, isRecordingDate: isRecordingDate, warnings: warnings)
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
