import AVFoundation
@preconcurrency import FluidAudio
import Foundation
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "transcription")

/// Turns a Speaker's samples into the embedding of their voice, locally with WeSpeaker through
/// FluidAudio, to recognise voices named in past Meetings (`VoiceLibrary`). The models, about
/// 22 MB, are downloaded on first use into Takku's models folder and stay loaded for the whole app.
actor VoiceRecognizer {
    private var manager: DiarizerManager?

    /// One embedding for the Speaker from the samples that can be read, `nil` if none can.
    func embedding(of samples: [SpeakerSample], in recording: Recording, directory: URL) async throws -> [Float]? {
        let manager = try await loaded()
        var embeddings: [[Float]] = []
        for sample in samples {
            guard let audio = try? Self.audio(of: sample, in: recording, directory: directory), !audio.isEmpty else { continue }
            let embedding = try manager.extractSpeakerEmbedding(from: audio)
            if manager.validateEmbedding(embedding) { embeddings.append(embedding) }
        }
        return VoiceLibrary.mean(embeddings)
    }

    /// The sample's stretch of the Others Track, 16 kHz mono like every Segment.
    private static func audio(of sample: SpeakerSample, in recording: Recording, directory: URL) throws -> [Float] {
        guard let (segment, offset) = recording.segment(of: .others, at: sample.start) else { return [] }
        let file = try AVAudioFile(forReading: directory.appending(path: segment.fileName))
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(offset * rate)
        // A sample may run past the end of its Segment: it is cut there.
        let frames = AVAudioFrameCount(min(sample.duration * rate, Double(max(0, file.length - file.framePosition))))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return [] }
        try file.read(into: buffer, frameCount: frames)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func loaded() async throws -> DiarizerManager {
        if let manager { return manager }
        let started = ContinuousClock.now
        // FluidAudio puts the models in a `speaker-diarization` folder next to the one it is given.
        let folder = await TranscriptionModels.directory.appending(path: "fluidaudio/speaker-diarization", directoryHint: .isDirectory)
        let models = try await DiarizerModels.download(to: folder)
        let manager = DiarizerManager()
        manager.initialize(models: models)
        logger.notice("Voice recognition models loaded in \(secondsSince(started), privacy: .public)")
        self.manager = manager
        return manager
    }
}
