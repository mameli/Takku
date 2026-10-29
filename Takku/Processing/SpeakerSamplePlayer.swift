import AVFoundation
import Foundation
import Observation
import os
import TakkuCore

private let logger = Logger(subsystem: "app.takku.takku", category: "processing")

/// Plays a few seconds of a Speaker's voice from the Others Track of a Recording, one sample at a
/// time. Each new play of the same Speaker moves on to their next sample, in case someone else was
/// speaking over the first one.
@MainActor
@Observable
final class SpeakerSamplePlayer {
    private let recording: Recording
    private let directory: URL
    /// The Speaker being played, if any.
    private(set) var playing: Int?
    /// The sample of each Speaker played last, or shown before any is played.
    private(set) var selected: [Int: Int] = [:]
    private(set) var error: String?
    @ObservationIgnored private var played: Set<Int> = []
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    init(recording: Recording, directory: URL) {
        self.recording = recording
        self.directory = directory
    }

    /// Stops the Speaker being played, otherwise plays their next sample.
    func toggle(_ speaker: Int, samples: [SpeakerSample]) {
        if playing == speaker {
            stop()
            return
        }
        stop()
        guard !samples.isEmpty else { return }
        let index = played.contains(speaker) ? (selected[speaker, default: 0] + 1) % samples.count : 0
        played.insert(speaker)
        selected[speaker] = index
        let sample = samples[index]
        guard let (segment, offset) = recording.segment(of: .others, at: sample.start) else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: directory.appending(path: segment.fileName))
            player.currentTime = offset
            guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
            self.player = player
            playing = speaker
            error = nil
            // A sample may run past the end of its Segment: the player simply stops there first.
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(sample.duration))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            logger.error("Speaker sample not played: \(error, privacy: .public)")
            self.error = String(localized: "Cannot play the audio: \(error.localizedDescription)")
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        playing = nil
    }
}
