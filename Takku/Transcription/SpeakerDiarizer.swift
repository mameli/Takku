@preconcurrency import FluidAudio
import Foundation
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "transcription")

/// Tells the voices of the Others Track apart (diarization), locally with FluidAudio's offline
/// pipeline (pyannote community-1). The models, about 22 MB, are downloaded on first use into
/// Takku's models folder and stay loaded for the whole app. Processing runs one Meeting at a
/// time, so there is one request at a time.
actor SpeakerDiarizer {
    private var manager: OfflineDiarizerManager?

    /// The turns of each voice in the audio file, with times from its start. The file is read
    /// from disk as needed, not loaded whole.
    func turns(inFile url: URL) async throws -> [SpeakerTurn] {
        let manager = try await loaded()
        let started = ContinuousClock.now
        defer { logger.notice("Diarization pipeline ran in \(secondsSince(started), privacy: .public)") }
        return try await manager.process(url).segments.map {
            SpeakerTurn(voice: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds))
        }
    }

    private func loaded() async throws -> OfflineDiarizerManager {
        if let manager { return manager }
        let started = ContinuousClock.now
        let manager = OfflineDiarizerManager()
        // FluidAudio puts the models in a `speaker-diarization` folder under the one it is given.
        try await manager.prepareModels(directory: TranscriptionModels.directory.appending(path: "fluidaudio", directoryHint: .isDirectory))
        logger.notice("Diarization models loaded in \(secondsSince(started), privacy: .public)")
        self.manager = manager
        return manager
    }
}
