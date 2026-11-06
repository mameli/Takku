@preconcurrency import FluidAudio
import Foundation
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "transcription")

/// Silero voice activity detection through FluidAudio: the speech probability of every 256 ms of
/// a Segment, to drop the sentences the recognizer makes up where nobody speaks. The model, a few
/// MB, is downloaded on first use into Takku's models folder and stays loaded for the whole app.
/// It is optional: when it cannot be loaded the Transcript is made without it.
actor SpeechDetector {
    /// The model being loaded or loaded, shared by every Segment: the Segments of a Meeting are
    /// measured in parallel, and loading once per caller made them download the same files over
    /// each other. `nil` result: loading failed in this run of the app, not tried on every Segment.
    private var loading: Task<VadManager?, Never>?

    /// One probability per 256 ms of 16 kHz mono `samples`, `nil` when the detector is not available.
    func speechProbabilities(_ samples: [Float]) async -> [Float]? {
        guard !samples.isEmpty, let manager = await loaded() else { return nil }
        do {
            return try await manager.process(samples).map(\.probability)
        } catch {
            logger.error("Speech detection failed: \(error.logCode, privacy: .public) \(error, privacy: .private)")
            return nil
        }
    }

    private func loaded() async -> VadManager? {
        if let loading { return await loading.value }
        let loading = Task<VadManager?, Never> {
            let started = ContinuousClock.now
            // FluidAudio puts the model in a `Models` folder under the one it is given.
            let folder = await TranscriptionModels.directory.appending(path: "fluidaudio", directoryHint: .isDirectory)
            do {
                let manager = try await VadManager(config: VadConfig(defaultThreshold: SegmentSignal.speechThreshold), modelDirectory: folder)
                logger.notice("Speech detection model loaded in \(secondsSince(started), privacy: .public)")
                return manager
            } catch {
                logger.error("Speech detection model not loaded: \(error.logCode, privacy: .public) \(error, privacy: .private)")
                return nil
            }
        }
        self.loading = loading
        return await loading.value
    }
}
