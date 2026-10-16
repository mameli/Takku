@preconcurrency import FluidAudio
import Foundation
import NaturalLanguage
import TakkuCore
@preconcurrency import WhisperKit
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "transcription")

/// Local speech recognition: Whisper through WhisperKit or Parakeet through FluidAudio. One model
/// loaded at a time for the whole app (the one the request asks for), one request at a time.
actor LocalTranscriber {
    /// Recognised in an audio buffer, with times relative to the start of the buffer.
    struct RecognizedText: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    /// Where the model is, shown in the menu while it is not ready. The download is reported
    /// by `TranscriptionModels`.
    enum ModelPhase: Equatable, Sendable {
        case notLoaded
        /// `firstTime` right after the download: macOS then prepares the model for the Neural
        /// Engine, which takes a few minutes once. Otherwise loading takes seconds.
        case loading(TranscriptionModel, firstTime: Bool)
        case ready
    }

    private let models: TranscriptionModels
    private var onPhase: @Sendable (ModelPhase) -> Void = { _ in }
    private enum Engine {
        case whisper(WhisperKit)
        case parakeet(AsrManager)
    }

    private var engine: Engine?
    private var loadedModel: TranscriptionModel?
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(models: TranscriptionModels) {
        self.models = models
    }

    /// `handler` is called from any thread whenever the model changes phase.
    func setPhaseHandler(_ handler: @escaping @Sendable (ModelPhase) -> Void) {
        onPhase = handler
    }

    /// Downloads the model on first use and loads it in memory. Later calls are immediate.
    func prepare(_ model: TranscriptionModel) async throws {
        await acquire()
        defer { release() }
        _ = try await loaded(model)
    }

    /// The most likely of `languages` (the Meeting languages ticked in Settings).
    func detectLanguage(_ samples: [Float], among languages: [String], model: TranscriptionModel) async throws -> String {
        await acquire()
        defer { release() }
        switch try await loaded(model) {
        case .whisper(let whisperKit):
            let (_, probabilities) = try await whisperKit.detectLangauge(audioArray: samples)
            return languages.max {
                probabilities[$0, default: -.infinity] < probabilities[$1, default: -.infinity]
            }!
        case .parakeet(let asr):
            // Parakeet does not say which language it heard: it is read from the text.
            var state = TdtDecoderState.make()
            let text = try await asr.transcribe(samples, decoderState: &state).text
            return Self.language(of: text, among: languages)
        }
    }

    /// Which of `languages` the text is most likely in; the first one when the text says nothing.
    private static func language(of text: String, among languages: [String]) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = languages.map { NLLanguage($0) }
        recognizer.processString(text)
        return recognizer.dominantLanguage.map(\.rawValue).flatMap { languages.contains($0) ? $0 : nil }
            ?? MeetingLanguages.fallback(languages)
    }

    /// `language` is followed by Whisper; Parakeet picks the language by itself.
    func transcribe(_ samples: [Float], language: String, model: TranscriptionModel) async throws -> [RecognizedText] {
        await acquire()
        defer { release() }
        let whisperKit: WhisperKit
        switch try await loaded(model) {
        case .whisper(let loaded):
            whisperKit = loaded
        case .parakeet(let asr):
            var state = TdtDecoderState.make()
            let result = try await asr.transcribe(samples, decoderState: &state)
            let tokens = (result.tokenTimings ?? []).map {
                TimedText(text: $0.token, start: $0.startTime, end: $0.endTime)
            }
            if tokens.isEmpty {
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? [] : [RecognizedText(start: 0, end: result.duration, text: text)]
            }
            return sentences(from: tokens).map { RecognizedText(start: $0.start, end: $0.end, text: $0.text) }
        }
        // Speech is already guaranteed by the ranges MeetingTranscription passes in: Whisper's
        // "no speech" threshold would only drop degraded audio (voices coming through a phone).
        let options = DecodingOptions(
            language: language,
            detectLanguage: false,
            skipSpecialTokens: true,
            noSpeechThreshold: nil,
            chunkingStrategy: .vad
        )
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return results.flatMap(\.segments).map {
            RecognizedText(start: TimeInterval($0.start), end: TimeInterval($0.end), text: $0.text)
        }
    }

    /// The model in memory, downloading and loading it if it is another one (only one is kept:
    /// the large ones take gigabytes).
    private func loaded(_ model: TranscriptionModel) async throws -> Engine {
        if let engine, loadedModel == model { return engine }
        engine = nil
        loadedModel = nil
        let started = ContinuousClock.now
        logger.notice("Loading \(model.id, privacy: .public)")
        do {
            let (folder, downloadedNow) = try await models.ensureDownloaded(model)
            onPhase(.loading(model, firstTime: downloadedNow))
            let loaded: Engine
            switch model.engine {
            case .whisper:
                // The tokenizer is downloaded the first time too, into the models folder.
                loaded = .whisper(try await WhisperKit(WhisperKitConfig(
                    model: model.id,
                    downloadBase: TranscriptionModels.directory,
                    modelFolder: folder.path(percentEncoded: false),
                    verbose: false,
                    logLevel: .error,
                    download: false
                )))
            case .parakeet:
                let models = try await AsrModels.load(from: folder, version: .v3)
                loaded = .parakeet(AsrManager(config: .default, models: models))
            }
            engine = loaded
            loadedModel = model
            logger.notice("\(model.id, privacy: .public) loaded in \(secondsSince(started), privacy: .public)")
            onPhase(.ready)
            return loaded
        } catch {
            onPhase(.notLoaded)
            throw error
        }
    }

    // Neither engine guarantees safe concurrent requests: one at a time, in arrival order.

    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
