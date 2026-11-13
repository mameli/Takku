@preconcurrency import FluidAudio
import Foundation
import Observation
@preconcurrency import WhisperKit
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "transcription")

/// A speech recognition model Takku offers: multilingual (Italian and English) unless
/// `isEnglishOnly`.
struct TranscriptionModel: Identifiable, Hashable, Sendable {
    enum Engine: Sendable {
        /// OpenAI Whisper through WhisperKit: `id` is the folder in argmaxinc/whisperkit-coreml.
        case whisper
        /// NVIDIA Parakeet TDT v3, or a model derived from it, through FluidAudio: `id` is the
        /// folder FluidAudio downloads it into (its repo's `folderName`).
        case parakeet(AsrModelVersion)
    }

    let id: String
    let engine: Engine
    let name: String
    let downloadMB: Int
    let note: LocalizedStringResource
    /// Shown first in Settings; the others are under *Other models*.
    var isFeatured = false
    /// Transcribes English only: a Meeting in another language comes out wrong.
    var isEnglishOnly = false

    /// The four offered first (the most accurate, the one always in the Meeting language, the
    /// lightest, the English one), then every other model that loads by its name alone.
    static let all = [
        TranscriptionModel(
            id: "parakeet-ultra", engine: .parakeet(.ultra), name: "Parakeet Ultra",
            downloadMB: 632, note: "Recommended: the most accurate, and fast; on short replies it can switch language.",
            isFeatured: true
        ),
        TranscriptionModel(
            id: "openai_whisper-large-v3-v20240930_turbo_632MB", engine: .whisper, name: "Whisper Large v3 Turbo",
            downloadMB: 646, note: "Fast and accurate; always in the Meeting language.",
            isFeatured: true
        ),
        TranscriptionModel(
            id: "parakeet-redux", engine: .parakeet(.redux), name: "Parakeet Redux",
            downloadMB: 220, note: "The lightest: a third of the download, a little less accurate and slower.",
            isFeatured: true
        ),
        TranscriptionModel(
            id: "phonon-2", engine: .parakeet(.phonon2), name: "Phonon-2",
            downloadMB: 360, note: "English only: the fastest, nearly as accurate as Parakeet Ultra in English.",
            isFeatured: true, isEnglishOnly: true
        ),
        TranscriptionModel(
            id: "parakeet-tdt-0.6b-v3", engine: .parakeet(.v3), name: "Parakeet v3",
            downloadMB: 490, note: "What Parakeet Ultra was trained from: as fast, less accurate."
        ),
        TranscriptionModel(
            id: "openai_whisper-large-v3-v20240930_turbo", engine: .whisper, name: "Whisper Large v3 Turbo (full)",
            downloadMB: 1_638, note: "Slightly more accurate; more memory, slower to prepare."
        ),
        TranscriptionModel(
            id: "openai_whisper-large-v3_947MB", engine: .whisper, name: "Whisper Large v3",
            downloadMB: 948, note: "The original Large v3: accurate, several times slower than Turbo."
        ),
        TranscriptionModel(
            id: "openai_whisper-large-v3", engine: .whisper, name: "Whisper Large v3 (full)",
            downloadMB: 3_090, note: "Uncompressed: much more memory, slow to prepare."
        ),
        TranscriptionModel(
            id: "openai_whisper-large-v2_949MB", engine: .whisper, name: "Whisper Large v2",
            downloadMB: 952, note: "The previous generation of Whisper."
        ),
        TranscriptionModel(
            id: "openai_whisper-medium", engine: .whisper, name: "Whisper Medium",
            downloadMB: 1_529, note: "Less accurate than Large v3 Turbo, and slower."
        ),
        TranscriptionModel(
            id: "openai_whisper-small_216MB", engine: .whisper, name: "Whisper Small",
            downloadMB: 217, note: "Light and fast; more mistakes, especially in Italian."
        ),
        TranscriptionModel(
            id: "openai_whisper-base", engine: .whisper, name: "Whisper Base",
            downloadMB: 146, note: "Very light; many mistakes."
        ),
        TranscriptionModel(
            id: "openai_whisper-tiny", engine: .whisper, name: "Whisper Tiny",
            downloadMB: 76, note: "The smallest; to try things out, not for meetings."
        ),
        TranscriptionModel(
            id: "phonon-2.5", engine: .parakeet(.phonon25), name: "Phonon-2.5",
            downloadMB: 290, note: "Light, on the graphics card; less accurate than Parakeet in Italian."
        ),
        TranscriptionModel(
            id: "bark-3.0", engine: .parakeet(.bark3), name: "Bark 3.0",
            downloadMB: 440, note: "English only: word for word, fillers and repeats included.",
            isEnglishOnly: true
        ),
        TranscriptionModel(
            id: "bark-3.0-clean", engine: .parakeet(.bark3Clean), name: "Bark 3.0 Clean",
            downloadMB: 450, note: "English only: drops fillers, false starts and repeats.",
            isEnglishOnly: true
        ),
    ]

    /// For a new install: Parakeet Ultra since 1.10.0.
    static let `default` = all.first { $0.id == "parakeet-ultra" }!
    /// The default up to 1.9.0, Large v3 Turbo: what made the Segment caches written before models
    /// could be chosen, and what a Mac that never chose one keeps (see `keepPreviousDefault`).
    static let previousDefault = all.first { $0.id == "openai_whisper-large-v3-v20240930_turbo_632MB" }!

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The model chosen in Settings; the default if the saved one is no longer offered.
    static var selected: TranscriptionModel {
        all.first { $0.id == AppSettings.transcriptionModelID } ?? .default
    }
}

/// The models on this Mac: which ones are downloaded, downloads in progress, deletion. A model
/// is downloaded once, from Settings or at the first Meeting that needs it; only one download
/// per model runs at a time.
@MainActor
@Observable
final class TranscriptionModels {
    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Takku/Models", directoryHint: .isDirectory)
    }

    /// Written next to a model once it is fully downloaded: a download interrupted halfway is
    /// resumed instead of being loaded.
    private static let downloadedMarker = ".takku-downloaded"

    /// Whole percent of the downloads in progress, by model. 100 while the model is still being
    /// prepared: FluidAudio reports the end before macOS has compiled all of Parakeet.
    private(set) var progress: [String: Int] = [:]
    /// Changes whenever a model is downloaded or deleted, so views read the disk again.
    private(set) var revision = 0
    /// Called with every whole-percent step of a download, and with `nil` when it ends, also on
    /// failure (the menu updates its item in place).
    @ObservationIgnored var onProgress: (TranscriptionModel, Int?) -> Void = { _, _ in }
    @ObservationIgnored private var downloads: [String: Task<URL, Error>] = [:]

    static func folder(of model: TranscriptionModel) -> URL {
        switch model.engine {
        case .whisper:
            directory.appending(path: "models/argmaxinc/whisperkit-coreml/\(model.id)", directoryHint: .isDirectory)
        case .parakeet:
            // FluidAudio downloads into a folder named after the model, under the one it is given.
            directory.appending(path: "fluidaudio/\(model.id)", directoryHint: .isDirectory)
        }
    }

    /// A Mac that never chose a model and has the previous default downloaded keeps it: with the
    /// new default it would download another model at its next Meeting, and transcribe differently.
    func keepPreviousDefault() {
        guard AppSettings.transcriptionModelID == nil, isDownloaded(.previousDefault) else { return }
        AppSettings.transcriptionModelID = TranscriptionModel.previousDefault.id
        logger.notice("No model chosen, the previous default is downloaded: it stays in use")
    }

    func isDownloaded(_ model: TranscriptionModel) -> Bool {
        _ = revision
        return FileManager.default.fileExists(
            atPath: Self.folder(of: model).appending(path: Self.downloadedMarker).path(percentEncoded: false)
        )
    }

    var downloaded: [TranscriptionModel] {
        TranscriptionModel.all.filter(isDownloaded)
    }

    /// The model's folder, downloading it first if needed. `downloadedNow` is true when it was
    /// downloaded by this call (or by one already running): macOS then still has to prepare it.
    func ensureDownloaded(_ model: TranscriptionModel) async throws -> (folder: URL, downloadedNow: Bool) {
        if isDownloaded(model) { return (Self.folder(of: model), false) }
        let task = downloads[model.id] ?? startDownload(model)
        return (try await task.value, true)
    }

    /// Starts the download from Settings; errors are shown there.
    func download(_ model: TranscriptionModel) async throws {
        _ = try await ensureDownloaded(model)
    }

    func delete(_ model: TranscriptionModel) throws {
        try FileManager.default.removeItem(at: Self.folder(of: model))
        if case .whisper = model.engine {
            // WhisperKit's download metadata for that model: without it a new download starts clean.
            let metadata = Self.directory.appending(path: "models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/\(model.id)")
            try? FileManager.default.removeItem(at: metadata)
        }
        revision += 1
    }

    private func startDownload(_ model: TranscriptionModel) -> Task<URL, Error> {
        progress[model.id] = 0
        onProgress(model, 0)
        // Strong references: the list lives as long as the app.
        let task = Task { () throws -> URL in
            defer {
                progress[model.id] = nil
                downloads[model.id] = nil
                revision += 1
                onProgress(model, nil)
            }
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let report: @Sendable (Double) -> Void = { fraction in
                Task { @MainActor in self.report(model, Int(fraction * 100)) }
            }
            let folder: URL
            switch model.engine {
            case .whisper:
                folder = try await WhisperKit.download(variant: model.id, downloadBase: Self.directory) {
                    report($0.fractionCompleted)
                }
            case .parakeet(let version):
                folder = try await AsrModels.download(to: Self.folder(of: model), version: version) {
                    report($0.fractionCompleted)
                }
            }
            try Data().write(to: folder.appending(path: Self.downloadedMarker))
            logger.info("Downloaded \(model.id, privacy: .public)")
            return folder
        }
        downloads[model.id] = task
        return task
    }

    /// Whole percents only, and never backwards: progress reports arrive many times a second
    /// and not always in order.
    private func report(_ model: TranscriptionModel, _ percent: Int) {
        guard let current = progress[model.id], percent > current else { return }
        progress[model.id] = percent
        onProgress(model, percent)
    }
}
