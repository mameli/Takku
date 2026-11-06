import Accelerate
import AVFoundation
import TakkuCore

/// Receives the buffers of an audio source with the host time of their first frame.
typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, UInt64) -> Void

/// Called from the audio thread when a Segment is complete on disk, with the Recording folder.
typealias SegmentClosedHandler = @Sendable (Segment, URL) -> Void

/// Converts the audio of a Track to mono 16 kHz and writes it in AAC Segments.
///
/// `write` is called from the source's audio thread, `finish` from the main thread
/// after the source has stopped: the lock serialises the two.
final class SegmentedTrackWriter: @unchecked Sendable {
    /// The Segments written and, if there was one, the error that interrupted the Track.
    struct Outcome {
        let segments: [Segment]
        let error: Error?
    }

    private static var fileSettings: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Recording.sampleRate, AVNumberOfChannelsKey: 1]
    }

    private let track: Track
    private let directory: URL
    private let meetingStartHostTime: UInt64
    private let segmentDuration: TimeInterval
    private let onSegmentClosed: SegmentClosedHandler
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Recording.sampleRate, channels: 1, interleaved: false
    )!
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var segmenter: TrackSegmenter?
    private var file: AVAudioFile?
    private var fileIndex: Int?
    private var firstError: Error?
    private var isFinished = false
    private var lastSound: TimeInterval?

    /// `onSegmentClosed` fires at every Segment change; the last Segment closes with `finish`.
    init(
        track: Track,
        directory: URL,
        meetingStartHostTime: UInt64,
        segmentDuration: TimeInterval,
        onSegmentClosed: @escaping SegmentClosedHandler
    ) {
        self.track = track
        self.directory = directory
        self.meetingStartHostTime = meetingStartHostTime
        self.segmentDuration = segmentDuration
        self.onSegmentClosed = onSegmentClosed
    }

    /// Segment list updated at every opening: if the app crashes before the stop,
    /// the offsets stay on disk.
    var segmentsFileURL: URL {
        directory.appending(path: Segment.listFileName(for: track))
    }

    func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        lock.withLock {
            // A buffer can arrive from the audio thread even after the stop.
            guard !isFinished, firstError == nil else { return }
            do {
                try writeLocked(buffer, hostTime: hostTime)
            } catch {
                firstError = error
            }
        }
    }

    /// When the Track last received sound, in seconds from the start of the Meeting; `nil` if never.
    /// The silence written to fill holes does not count.
    var lastSoundTime: TimeInterval? {
        lock.withLock { lastSound }
    }

    func finish() -> Outcome {
        lock.withLock {
            isFinished = true
            file?.close()
            file = nil
            return Outcome(segments: segmenter?.segments ?? [], error: firstError)
        }
    }

    private func writeLocked(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) throws {
        let converted = try convert(buffer)
        guard converted.frameLength > 0 else { return }

        let start = secondsSinceMeetingStart(hostTime)
        if Self.peak(of: converted) > TrackSilence.soundThreshold {
            lastSound = start + Double(converted.frameLength) / Recording.sampleRate
        }
        if let segmenter {
            try appendSilence(frames: segmenter.silenceFrames(beforeBufferAt: start))
        } else {
            segmenter = TrackSegmenter(
                track: track,
                sampleRate: Recording.sampleRate,
                trackStart: start,
                segmentDuration: segmentDuration
            )
        }
        try append(converted)
    }

    /// Fills a hole in the audio (the source stopped for a while) in blocks of at most 10 seconds.
    private func appendSilence(frames: Int) throws {
        var remaining = frames
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, Int(10 * Recording.sampleRate)))
            let silence = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: count)!
            silence.frameLength = count
            silence.floatChannelData![0].update(repeating: 0, count: Int(count))
            try append(silence)
            remaining -= Int(count)
        }
    }

    private func append(_ converted: AVAudioPCMBuffer) throws {
        let previous = segmenter!.segments.last
        let segment = segmenter!.place(frameCount: Int(converted.frameLength))
        if segment.index != fileIndex {
            if let file, let previous {
                file.close()
                onSegmentClosed(previous, directory)
            }
            file = try AVAudioFile(
                forWriting: directory.appending(path: segment.fileName),
                settings: Self.fileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            fileIndex = segment.index
            try JSONEncoder().encode(segmenter!.segments).write(to: segmentsFileURL, options: .atomic)
        }
        try file!.write(from: converted)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if converter?.inputFormat != buffer.format {
            guard let newConverter = AVAudioConverter(from: buffer.format, to: outputFormat) else {
                throw CaptureError.unsupportedFormat(buffer.format.description)
            }
            if buffer.format.channelCount > 2 {
                // Multichannel input (audio interfaces, Recordings made with voice processing
                // up to 1.5.1, whose channel 0 is the one cleaned of echo): the first channel.
                newConverter.channelMap = [0]
            } else {
                newConverter.downmix = true
            }
            converter = newConverter
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let frames = (Double(buffer.frameLength) * ratio).rounded(.up)
        guard frames.isFinite, frames < Double(UInt32.max) - 1 else {
            throw CaptureError.unsupportedFormat(buffer.format.description)
        }
        let capacity = AVAudioFrameCount(frames) + 1
        let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)!

        var consumed = false
        var conversionError: NSError?
        let status = converter!.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error, let conversionError { throw conversionError }
        return output
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        var peak: Float = 0
        vDSP_maxmgv(buffer.floatChannelData![0], 1, &peak, vDSP_Length(buffer.frameLength))
        return peak
    }

    private func secondsSinceMeetingStart(_ hostTime: UInt64) -> TimeInterval {
        guard hostTime > meetingStartHostTime else { return 0 }
        return AVAudioTime.seconds(forHostTime: hostTime - meetingStartHostTime)
    }
}
