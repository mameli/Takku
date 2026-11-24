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

    /// `meetingID`: chosen by `takku import`, so the command can follow the Meeting (ADR 0015).
    static func run(
        _ url: URL, meetingID: UUID = UUID(), into recordingsDirectory: URL, segmentDuration: TimeInterval
    ) async throws -> Imported {
        let name = url.lastPathComponent
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw CaptureError.unreadableFile(name)
        }
        guard file.length > 0 else { throw CaptureError.noAudio(name) }
        let sampleRate = file.processingFormat.sampleRate
        // A header can declare 0 Hz and the decoder still opens the file: the conversion would divide by it.
        guard sampleRate.isFinite, sampleRate > 0 else { throw CaptureError.unsupportedFormat(file.processingFormat.description) }
        let (startedAt, isRecordingDate) = await startDate(of: url)
        // AVAudioFile can see only the start of some MP4s and stop there with no error (175 s of a
        // 19-minute video merged by yt-dlp); AVAssetReader sees the whole track.
        let declared = Double(file.length) / sampleRate
        let trackDuration = await audioTrackDuration(of: url)
        let readsWholeTrack = trackDuration.map { $0 - declared <= max(1, $0 / 100) } ?? true
        if !readsWholeTrack, let trackDuration {
            logger.notice("\(name, privacy: .private): AVAudioFile sees \(Int(declared)) s of \(Int(trackDuration)) s, read with AVAssetReader")
        }

        let directory = recordingsDirectory.appending(path: meetingID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            // The writer places each buffer by its host time: here, its position in the file.
            let writer = SegmentedTrackWriter(
                track: .others, directory: directory, meetingStartHostTime: 0,
                segmentDuration: segmentDuration, onSegmentClosed: { _, _ in }
            )
            let reading = readsWholeTrack ? try read(file, into: writer) : try await readWithAssetReader(url, into: writer)
            let outcome = writer.finish()
            if let error = outcome.error { throw error }
            if outcome.segments.isEmpty, let firstError = reading.firstError { throw firstError }
            var warnings: [String] = []
            for stretch in reading.skipped {
                let start = Double(stretch.lowerBound) / sampleRate, end = Double(stretch.upperBound) / sampleRate
                logger.warning("Skipped unreadable audio in \(name, privacy: .private) from \(start, format: .fixed(precision: 3)) s to \(end, format: .fixed(precision: 3)) s")
                warnings.append(String(localized: "Unreadable audio skipped from \(String(format: "%.3f", start)) s to \(String(format: "%.3f", end)) s; the Transcript and Summary may be incomplete."))
            }
            if let firstError = reading.firstError {
                logger.notice("Read errors in \(name, privacy: .private), stretches skipped: \(reading.skipped.count); the first error: \(firstError, privacy: .private)")
            }
            let recording = Recording(
                meetingID: meetingID, startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(reading.duration), segments: outcome.segments
            )
            try recording.save(inFolder: directory)
            return Imported(directory: directory, recording: recording, isRecordingDate: isRecordingDate, warnings: warnings)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// What a read of the file gave: how long it is, and the stretches it could not decode.
    private struct Reading {
        var duration: TimeInterval
        var skipped: [Range<AVAudioFramePosition>] = []
        var firstError: Error?
    }

    private static func read(_ file: AVAudioFile, into writer: SegmentedTrackWriter) throws -> Reading {
        let sampleRate = file.processingFormat.sampleRate
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
        return Reading(duration: Double(file.length) / sampleRate, skipped: skipped, firstError: firstError)
    }

    /// The whole audio track, decoded by AVAssetReader at its own sample rate and channels. A
    /// failure ends the import: what could be read is not the whole file.
    private static func readWithAssetReader(_ url: URL, into writer: SegmentedTrackWriter) async throws -> Reading {
        let name = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CaptureError.noAudio(name) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true, AVLinearPCMIsBigEndianKey: false,
        ])
        guard reader.canAdd(output) else { throw CaptureError.unreadableFile(name) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CaptureError.unreadableFile(name) }
        var frames: AVAudioFramePosition = 0
        var sampleRate: Double = 0
        // One format for the whole track, so the writer keeps one converter.
        var format: AVAudioFormat?
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            if format == nil, let description = CMSampleBufferGetFormatDescription(sample),
               let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                format = AVAudioFormat(streamDescription: stream)
            }
            guard count > 0, let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
            else { continue }
            buffer.frameLength = AVAudioFrameCount(count)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList
            )
            guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            sampleRate = format.sampleRate
            writer.write(buffer, hostTime: AVAudioTime.hostTime(forSeconds: Double(frames) / sampleRate))
            frames += AVAudioFramePosition(count)
        }
        if reader.status == .failed { throw reader.error ?? CaptureError.unreadableFile(name) }
        guard frames > 0 else { throw CaptureError.noAudio(name) }
        return Reading(duration: Double(frames) / sampleRate)
    }

    /// How long the file's audio track is, as AVFoundation's asset sees it; `nil` if it cannot tell.
    private static func audioTrackDuration(of url: URL) async -> TimeInterval? {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first,
              let range = try? await track.load(.timeRange)
        else { return nil }
        let seconds = range.duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
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
