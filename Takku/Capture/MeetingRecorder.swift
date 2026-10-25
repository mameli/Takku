import AVFoundation
import TakkuCore

/// Records the two Tracks of a Meeting into its folder and saves the manifest.
@MainActor
final class MeetingRecorder {
    private struct Active {
        let meetingID: UUID
        let directory: URL
        let startedAt: Date
        let me: SegmentedTrackWriter
        let others: SegmentedTrackWriter
    }

    /// A Recording just started: the identifier is the Meeting's `takku_id`.
    struct Started {
        let meetingID: UUID
        let directory: URL
    }

    /// A closed Recording. `errors` lists the Tracks that were interrupted before the stop.
    struct Stopped {
        let directory: URL
        let recording: Recording
        let errors: [String]
    }

    private let microphone = MicrophoneCapture()
    private let systemAudio = SystemAudioCapture()
    private var active: Active?

    /// Where Recordings are kept, one folder per Meeting (named after its `takku_id`).
    static var recordingsDirectory: URL {
        #if DEBUG
        // Automated tests: test Recordings stay outside the real folder.
        if let path = UserDefaults.standard.string(forKey: "dataDirectory") {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Takku/Recordings", directoryHint: .isDirectory)
    }

    static var segmentDuration: TimeInterval {
        #if DEBUG
        // `--args -segmentSeconds 5` to test Segment rotation without waiting 5 minutes.
        let override = UserDefaults.standard.double(forKey: "segmentSeconds")
        if override > 0 { return override }
        #endif
        return TrackSegmenter.defaultSegmentDuration
    }

    func start(
        at startedAt: Date, onSegmentClosed: @escaping SegmentClosedHandler
    ) throws -> Started {
        let meetingID = UUID()
        let directory = Self.recordingsDirectory.appending(path: meetingID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let hostTime = mach_absolute_time()
        func writer(for track: Track) -> SegmentedTrackWriter {
            SegmentedTrackWriter(
                track: track,
                directory: directory,
                meetingStartHostTime: hostTime,
                segmentDuration: Self.segmentDuration,
                onSegmentClosed: onSegmentClosed
            )
        }
        let me = writer(for: .me)
        let others = writer(for: .others)

        do {
            // System tap first, then the microphone: opening the microphone can reconfigure
            // the audio devices (AirPods switch to call mode).
            try systemAudio.start { buffer, time in others.write(buffer, hostTime: time) }
            try microphone.start { buffer, time in me.write(buffer, hostTime: time) }
        } catch {
            microphone.stop()
            systemAudio.stop()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        active = Active(meetingID: meetingID, directory: directory, startedAt: startedAt, me: me, others: others)
        return Started(meetingID: meetingID, directory: directory)
    }

    /// When each Track of the Recording in progress last received sound (see `SegmentedTrackWriter.lastSoundTime`).
    func lastSoundTimes() -> [Track: TimeInterval?] {
        guard let active else { return [:] }
        return [.me: active.me.lastSoundTime, .others: active.others.lastSoundTime]
    }

    #if DEBUG
    func simulateMicrophoneChange() {
        microphone.simulateDeviceChange()
    }
    #endif

    /// Stops the capture, closes the Segments and writes `recording.json` with what there is,
    /// even if a Track was interrupted.
    func stop(at endedAt: Date) throws -> Stopped {
        guard let active else { preconditionFailure("stop without an active Recording") }
        self.active = nil
        microphone.stop()
        systemAudio.stop()

        let outcomes = [(Track.me, active.me.finish()), (Track.others, active.others.finish())]
        let recording = Recording(
            meetingID: active.meetingID,
            startedAt: active.startedAt,
            endedAt: endedAt,
            segments: outcomes.flatMap { $0.1.segments }
        )
        try recording.save(inFolder: active.directory)

        let errors = outcomes.compactMap { track, outcome in
            outcome.error.map { String(localized: "\(track.label) Track: \($0.localizedDescription)") }
        }
        return Stopped(directory: active.directory, recording: recording, errors: errors)
    }
}
