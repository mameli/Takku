import AVFoundation
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "transcription")

/// Transcribes the Segments of a Meeting as they close and, at the stop, writes
/// `transcript.md` in the Recording folder.
actor MeetingTranscription {
    /// The Transcript written, the language used (`nil` if there was no speech), the Segments
    /// that could not be transcribed and why the others could not be told apart, if they could not.
    struct Finished {
        let url: URL
        let transcript: Transcript
        let language: String?
        let failedSegments: [String]
        let speakersProblem: String?
    }

    /// Result of a Segment saved next to the audio: a new Processing does not redo it.
    private struct CachedSegment: CacheFile {
        /// The model that transcribed it; `nil` in caches written before models could be chosen,
        /// all made with the default one.
        let model: String?
        /// `nil` if the Segment contains no speech.
        let language: String?
        /// False when the language was detected on too little speech to trust it.
        let isLanguageReliable: Bool
        let utterances: [Utterance]
        /// Me Segments only: the peak level of each Utterance, for echo removal. `nil` in caches
        /// written before levels were kept: measured once on the audio and added.
        var levels: [Double?]?
        /// How `levels` were measured; `nil` in caches written before it was kept.
        var levelsVersion: Int? = CachedSegment.currentLevelsVersion
        /// Bump when `peakLevel` or the Utterance windowing changes: the levels are measured again.
        static let currentLevelsVersion = 1

        /// The levels if measured on these Utterances the current way, `nil` otherwise.
        var currentLevels: [Double?]? {
            levelsVersion == Self.currentLevelsVersion && levels?.count == utterances.count ? levels : nil
        }
    }

    /// The Speaker turns of the Others Track, kept in the Recording folder: a Retry does not
    /// diarize again unless the Others Segments changed.
    private struct CachedSpeakers: CacheFile {
        static let fileName = "speakers.json"
        /// Name, start and size of every Others Segment diarized.
        struct Source: Codable, Equatable {
            let fileName: String
            let start: TimeInterval
            let size: Int?
        }
        let segments: [Source]
        let turns: [SpeakerTurn]
        /// How the turns were found.
        var version = CachedSpeakers.currentVersion
        /// Bump when the diarizer or its model changes: the Others Track is diarized again.
        static let currentVersion = 1
    }

    private static let languageDetectionSeconds = 30.0
    /// Below this much speech (e.g. a short "ok") detection is unreliable: the language is
    /// used for that Segment only and detection is tried again on the next one.
    private static let minimumSpeechToLockLanguage = 10.0

    private let transcriber: LocalTranscriber
    private let diarizer: SpeakerDiarizer
    /// Fixed for the whole Meeting: Segments transcribed by another model are done again.
    private let model: TranscriptionModel
    /// The Meeting languages ticked in Settings at the start: detection picks among them.
    private let languages: [String]
    /// The only language ticked, if there is just one.
    private let forcedLanguage: String?
    /// The Meeting language, once detected on enough speech.
    private var languageDetection: Task<String, Error>?
    /// Segments transcribed with a language detected on too little speech, and that language:
    /// at the end they are transcribed again if the Meeting language turns out different.
    private var provisionalSegments: [String: (segment: Segment, language: String)] = [:]
    private var pending: [String: Task<CachedSegment, Error>] = [:]

    /// `languages`: the Meeting languages; with only one it is forced, otherwise detected among them.
    init(transcriber: LocalTranscriber, diarizer: SpeakerDiarizer, model: TranscriptionModel, languages: [String]) {
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.model = model
        self.languages = MeetingLanguages.normalized(languages)
        self.forcedLanguage = MeetingLanguages.forced(languages)
    }

    func segmentClosed(_ segment: Segment, in directory: URL) {
        startIfNeeded(segment, in: directory)
    }

    /// Transcribes the missing Segments, waits for those in progress and writes the Transcript.
    /// A failing Segment does not block the others: the Transcript comes out with a gap.
    func finish(_ recording: Recording, in directory: URL, vocabulary: Vocabulary) async throws -> Finished {
        let started = ContinuousClock.now
        let alreadyStarted = recording.segments.filter { pending[$0.fileName] != nil }.count
        for segment in recording.segments {
            startIfNeeded(segment, in: directory)
        }
        logger.notice("""
            Finishing the Transcript: \(recording.segments.count) Segments, \(alreadyStarted) started while recording, \
            model \(self.model.id, privacy: .public), languages \(self.languages, privacy: .public)
            """)
        var bySegment: [String: CachedSegment] = [:]
        var failed: [String] = []
        for segment in recording.segments {
            do {
                bySegment[segment.fileName] = try await pending[segment.fileName]!.value
            } catch {
                failed.append("\(segment.fileName): \(error.localizedDescription)")
                pending[segment.fileName] = nil
            }
        }
        logger.notice("Segments ready after \(secondsSince(started), privacy: .public), \(failed.count) failed")

        // A short first utterance may have been transcribed (or translated) in the wrong
        // language: once the Meeting language is known, those Segments are done again.
        var locked = forcedLanguage
        if locked == nil { locked = try? await languageDetection?.value }
        if let locked {
            for (fileName, provisional) in provisionalSegments where provisional.language != locked {
                do {
                    bySegment[fileName] = try await transcribe(provisional.segment, in: directory, language: locked)
                } catch {
                    failed.append("\(fileName): \(error.localizedDescription)")
                }
            }
        }
        bySegment = await Self.measuringMissingLevels(recording, bySegment, in: directory)

        // The echo removal, the Speakers, the Vocabulary variants and the Marks are applied here and not to
        // the cache: Retry on an old Recording benefits too. Only what they are computed from is cached
        // (Me levels, Speaker turns), so a Retry does not decode and diarize the audio again.
        var stage = ContinuousClock.now
        var utterances = removingEcho(removingEchoResidue(withMeLevels(recording, bySegment)))
        logger.notice("Echo removed in \(secondsSince(stage), privacy: .public)")
        // Without the Speakers the Transcript keeps "Others": it is a warning, not a failure.
        var speakersProblem: String?
        if utterances.contains(where: { $0.track == .others }) {
            stage = .now
            do {
                let turns = try await othersTurns(recording, in: directory)
                utterances = assigningSpeakers(to: utterances, turns: turns)
                logger.notice("Speakers told apart in \(secondsSince(stage), privacy: .public): \(turns.count) turns")
            } catch {
                speakersProblem = error.localizedDescription
                logger.error("Speakers not told apart after \(secondsSince(stage), privacy: .public): \(error, privacy: .public)")
            }
        }
        let url = directory.appending(path: Transcript.recordingCopyFileName)
        let transcript = Transcript(utterances: utterances, vocabulary: vocabulary)
            .marking(Marks.load(fromFolder: directory))
        try transcript.markdown.write(to: url, atomically: true, encoding: .utf8)
        let language = locked ?? provisionalSegments.values.first?.language
        logger.notice("Transcript written in \(secondsSince(started), privacy: .public), language \(language ?? "none", privacy: .public)")
        return Finished(
            url: url, transcript: transcript, language: language, failedSegments: failed, speakersProblem: speakersProblem
        )
    }

    /// The Utterances of every Segment with the cached peak level of the Me ones; `nil` where the
    /// levels could not be measured.
    private func withMeLevels(
        _ recording: Recording, _ bySegment: [String: CachedSegment]
    ) -> [(utterance: Utterance, level: Double?)] {
        recording.segments.flatMap { segment -> [(utterance: Utterance, level: Double?)] in
            guard let cached = bySegment[segment.fileName] else { return [] }
            let levels = cached.currentLevels ?? Array(repeating: nil, count: cached.utterances.count)
            return Array(zip(cached.utterances, levels))
        }
    }

    /// The peak level of each Utterance in the audio of the Segment starting at `start`.
    private static func levels(of utterances: [Utterance], in samples: [Float], startingAt start: TimeInterval) -> [Double?] {
        utterances.map { utterance in
            let from = max(0, Int((utterance.start - start) * Recording.sampleRate))
            let to = min(samples.count, Int((utterance.end - start) * Recording.sampleRate))
            return from < to ? peakLevel(of: samples[from..<to], sampleRate: Recording.sampleRate) : nil
        }
    }

    /// The voices of the whole Others Track, diarized in one pass so a voice keeps its number
    /// across Segments. The Segments are joined in a temporary file, each at its start with
    /// silence before it, so turn times are Meeting times and a long Meeting is not held in memory.
    private func othersTurns(_ recording: Recording, in directory: URL) async throws -> [SpeakerTurn] {
        let cacheURL = directory.appending(path: CachedSpeakers.fileName)
        let othersSegments = recording.segments.filter { $0.track == .others }.sorted { $0.start < $1.start }
        let key = othersSegments.map { segment in
            CachedSpeakers.Source(
                fileName: segment.fileName, start: segment.start,
                size: try? directory.appending(path: segment.fileName).resourceValues(forKeys: [.fileSizeKey]).fileSize
            )
        }
        if let cached = CachedSpeakers.load(at: cacheURL),
           cached.version == CachedSpeakers.currentVersion, cached.segments == key {
            logger.notice("Speakers from the cache")
            return cached.turns
        }
        let turns = try await diarizing(othersSegments, in: directory)
        // Turns missing an unreadable Segment are cached too: the key changes if that file does.
        try? CachedSpeakers(segments: key, turns: turns).save(to: cacheURL)
        return turns
    }

    /// The turns of the Segments that could be read.
    private func diarizing(_ othersSegments: [Segment], in directory: URL) async throws -> [SpeakerTurn] {
        let timeline = FileManager.default.temporaryDirectory.appending(path: "takku-others-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: timeline) }
        do { // The file is closed at the end of this block, before diarization reads it.
            let format = AVAudioFormat(standardFormatWithSampleRate: Recording.sampleRate, channels: 1)!
            let file = try AVAudioFile(forWriting: timeline, settings: format.settings)
            for segment in othersSegments {
                // An unreadable Segment (the one open during a crash) has no Utterances to label either.
                guard let samples = try? await Self.loadSamples(directory.appending(path: segment.fileName)) else { continue }
                let silence = max(0, Int(segment.start * Recording.sampleRate) - Int(file.length))
                try Self.write([Float](repeating: 0, count: silence), to: file, format: format)
                try Self.write(samples, to: file, format: format)
            }
        }
        return try await diarizer.turns(inFile: timeline)
    }

    private static func write(_ samples: [Float], to file: AVAudioFile, format: AVAudioFormat) throws {
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw TranscriptionError.unreadableAudio(file.url.lastPathComponent)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    private func startIfNeeded(_ segment: Segment, in directory: URL) {
        guard pending[segment.fileName] == nil else { return }
        pending[segment.fileName] = Task { try await self.transcribe(segment, in: directory, language: nil) }
    }

    /// `language` forces the language and ignores the cache; `nil` uses the cache or detects it.
    private func transcribe(_ segment: Segment, in directory: URL, language forced: String?) async throws -> CachedSegment {
        let cacheURL = directory.appending(path: segment.transcriptionCacheFileName)
        if let forced {
            logger.notice("\(segment.fileName, privacy: .public): transcribing again in \(forced, privacy: .public)")
        } else {
            let miss: String
            if let cached = CachedSegment.load(at: cacheURL) {
                guard let reason = cacheMiss(cached) else { return fromCache(cached, segment) }
                miss = reason
            } else {
                miss = FileManager.default.fileExists(atPath: cacheURL.path(percentEncoded: false)) ? "cache unreadable" : "no cache"
            }
            logger.notice("\(segment.fileName, privacy: .public): transcribing, \(miss, privacy: .public)")
        }
        let started = ContinuousClock.now
        defer { logger.notice("\(segment.fileName, privacy: .public): done in \(secondsSince(started), privacy: .public)") }

        let sampleRate = Recording.sampleRate
        let samples = try await Self.loadSamples(directory.appending(path: segment.fileName))
        // Whisper only gets the speech ranges: on silence and faint audio (echo residue,
        // distant voices) it makes up sentences such as "Grazie.".
        let ranges = speechRanges(in: samples, sampleRate: sampleRate)
        guard !ranges.isEmpty else {
            let silent = CachedSegment(model: model.id, language: nil, isLanguageReliable: true, utterances: [], levels: [])
            try silent.save(to: cacheURL)
            return silent
        }

        let (language, isReliable) = if let forced {
            (forced, true)
        } else {
            try await meetingLanguage(samples, speech: ranges)
        }
        if isReliable {
            provisionalSegments[segment.fileName] = nil
        } else {
            provisionalSegments[segment.fileName] = (segment, language)
        }

        var utterances: [Utterance] = []
        for range in ranges {
            let offset = segment.start + Double(range.lowerBound) / sampleRate
            let recognized = try await transcriber.transcribe(Array(samples[range]), language: language, model: model)
            let speech = speechSeconds(in: samples, range: range, sampleRate: sampleRate)
            if isLikelyHallucination(recognized.map(\.text), speechDuration: speech) { continue }
            utterances += recognized.map {
                Utterance(track: segment.track, start: offset + $0.start, end: offset + $0.end, text: $0.text)
            }
        }
        let levels = segment.track == .me ? Self.levels(of: utterances, in: samples, startingAt: segment.start) : nil
        let result = CachedSegment(
            model: model.id, language: language, isLanguageReliable: isReliable, utterances: utterances, levels: levels
        )
        try result.save(to: cacheURL)
        return result
    }

    /// A usable cached Segment: its language joins the Meeting's. Missing levels are measured in
    /// `finish`, once a provisional Segment is known to be kept.
    private func fromCache(_ cached: CachedSegment, _ segment: Segment) -> CachedSegment {
        logger.notice("\(segment.fileName, privacy: .public): from the cache")
        if let language = cached.language, forcedLanguage == nil {
            if cached.isLanguageReliable {
                // Same language for the whole Meeting, even if some Segments come from the cache.
                if languageDetection == nil { languageDetection = Task { language } }
            } else {
                provisionalSegments[segment.fileName] = (segment, language)
            }
        }
        return cached
    }

    /// Every Me Segment cached without current levels, measured on its audio (in parallel) and saved.
    private nonisolated static func measuringMissingLevels(
        _ recording: Recording, _ bySegment: [String: CachedSegment], in directory: URL
    ) async -> [String: CachedSegment] {
        await withTaskGroup(of: (String, CachedSegment).self) { group in
            for segment in recording.segments where segment.track == .me {
                guard let cached = bySegment[segment.fileName], !cached.utterances.isEmpty, cached.currentLevels == nil
                else { continue }
                group.addTask { (segment.fileName, await withLevels(cached, segment, in: directory)) }
            }
            var measured = bySegment
            for await (fileName, cached) in group { measured[fileName] = cached }
            return measured
        }
    }

    /// The Segment's cache with the peak level of each Utterance measured on the audio, and saved.
    /// It decodes the audio, so it runs off the actor.
    private nonisolated static func withLevels(_ cached: CachedSegment, _ segment: Segment, in directory: URL) async -> CachedSegment {
        guard let samples = try? await loadSamples(directory.appending(path: segment.fileName)) else { return cached }
        var measured = cached
        measured.levels = levels(of: cached.utterances, in: samples, startingAt: segment.start)
        measured.levelsVersion = CachedSegment.currentLevelsVersion
        try? measured.save(to: directory.appending(path: segment.transcriptionCacheFileName))
        return measured
    }

    /// One language per Meeting, detected once on up to 30 seconds of speech (silence
    /// confuses detection). It is locked only when there are at least 10 seconds of speech:
    /// on a short "ok" Whisper can pick the wrong language and then translate instead of
    /// transcribing. With less speech the language is returned as not reliable.
    private func meetingLanguage(_ samples: [Float], speech ranges: [Range<Int>]) async throws -> (String, Bool) {
        if let forcedLanguage { return (forcedLanguage, true) }
        if let languageDetection {
            do {
                return (try await languageDetection.value, true)
            } catch {
                self.languageDetection = nil
                throw error
            }
        }
        let limit = Int(Self.languageDetectionSeconds * Recording.sampleRate)
        var speech: [Float] = []
        for range in ranges where speech.count < limit {
            speech += samples[range].prefix(limit - speech.count)
        }
        let detection = Task { [transcriber, model, languages] in
            try await transcriber.detectLanguage(speech, among: languages, model: model)
        }
        let isReliable = Double(speech.count) >= Self.minimumSpeechToLockLanguage * Recording.sampleRate
        if isReliable { languageDetection = detection }
        do {
            return (try await detection.value, isReliable)
        } catch {
            if isReliable { languageDetection = nil }
            throw error
        }
    }

    /// Why a Segment's cache cannot be used, for the log; `nil` if it can. Without speech the model
    /// does not matter; otherwise model and language must be this Meeting's.
    private func cacheMiss(_ cached: CachedSegment) -> String? {
        guard let language = cached.language else { return nil }
        let cachedModel = cached.model ?? TranscriptionModel.default.id
        if cachedModel != model.id { return "cache made with \(cachedModel)" }
        return languages.contains(language) ? nil : "cached language \(language) is not among the Meeting languages"
    }

    /// Reads the Segment in 10-second blocks: a single read of minutes of AAC, with voice
    /// processing active in the same process, makes the macOS decoder spin forever. Async so that
    /// the decode runs off the actor, which other Segments wait for.
    private nonisolated static func loadSamples(_ url: URL) async throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let blockFrames = AVAudioFrameCount(10 * Recording.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockFrames) else {
            throw TranscriptionError.unreadableAudio(url.lastPathComponent)
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: blockFrames)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        return samples
    }
}

/// A cache kept next to the audio as JSON; an unreadable file counts as missing.
private protocol CacheFile: Codable {}

extension CacheFile {
    static func load(at url: URL) -> Self? {
        try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

enum TranscriptionError: LocalizedError {
    case unreadableAudio(String)

    var errorDescription: String? {
        switch self {
        case .unreadableAudio(let file): String(localized: "Cannot read the audio of \(file).")
        }
    }
}
