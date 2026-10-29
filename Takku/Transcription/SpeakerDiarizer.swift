import AVFoundation
@preconcurrency import FluidAudio
import Foundation
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "transcription")

/// Tells the voices of the Others Track apart (diarization), locally with NVIDIA's Nemotron 3
/// Diarization through FluidAudio, its `offline` preset: up to 8 voices. The model, about 190 MB,
/// is downloaded on first use into Takku's models folder and stays loaded for the whole app.
/// Processing runs one Meeting at a time, so there is one request at a time.
actor SpeakerDiarizer {
    enum Phase: Sendable {
        case preparing
        case identifying
    }

    private var diarizer: Nemotron3Diarizer?

    /// Audio read from the file at a time: the whole Track never sits in memory.
    private static let blockSeconds = 30.0

    /// The turns of each voice in the audio file (16 kHz mono), with times from its start. The
    /// file is read and fed to the model a block at a time, which gives the same turns as
    /// handing it the whole Track at once.
    func turns(inFile url: URL, onPhase: @escaping @Sendable (Phase) -> Void = { _ in }) async throws -> [SpeakerTurn] {
        let diarizer = try await loaded(onPhase: onPhase)
        onPhase(.identifying)
        let started = ContinuousClock.now
        defer { logger.notice("Diarization pipeline ran in \(secondsSince(started), privacy: .public)") }

        diarizer.reset()
        let file = try AVAudioFile(forReading: url)
        let blockFrames = AVAudioFrameCount(Self.blockSeconds * file.processingFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockFrames) else {
            throw TranscriptionError.unreadableAudio(url.lastPathComponent)
        }
        var probabilities: [Float] = []
        var frameCount = 0
        func collect(_ chunks: [Nemotron3ChunkResult]) {
            for chunk in chunks {
                probabilities.append(contentsOf: chunk.probabilities)
                frameCount += chunk.frameCount
            }
        }
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: blockFrames)
            guard buffer.frameLength > 0 else { break }
            diarizer.appendAudio(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
            collect(try diarizer.processBufferedAudio())
        }
        collect(try diarizer.finishStream())

        return Nemotron3Diarizer.segments(probabilities: probabilities, frameCount: frameCount).map {
            SpeakerTurn(voice: "S\($0.speakerIndex)", start: TimeInterval($0.startSeconds), end: TimeInterval($0.endSeconds))
        }
    }

    private func loaded(onPhase: @Sendable (Phase) -> Void) async throws -> Nemotron3Diarizer {
        if let diarizer { return diarizer }
        onPhase(.preparing)
        let started = ContinuousClock.now
        let folder = await TranscriptionModels.directory.appending(path: "fluidaudio", directoryHint: .isDirectory)
        // FluidAudio puts the model in a `nemotron-3-diarization` folder under the one it is given.
        let models = try await Nemotron3Models.loadFromHuggingFace(config: .offline, cacheDirectory: folder)
        let diarizer = Nemotron3Diarizer(config: .offline, models: models)
        logger.notice("Diarization model loaded in \(secondsSince(started), privacy: .public)")
        // The models of the pyannote pipeline used up to 1.10.0: only voice recognition still needs them.
        if !AppSettings.recognizeVoices {
            try? FileManager.default.removeItem(at: folder.appending(path: "speaker-diarization", directoryHint: .isDirectory))
        }
        self.diarizer = diarizer
        return diarizer
    }
}
