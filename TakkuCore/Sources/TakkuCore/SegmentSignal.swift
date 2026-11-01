import Accelerate
import Foundation

/// What the audio of a Segment says beyond its words, measured once on it and kept with its
/// transcription: the level of every 20 ms, for the echo removal, and the speech probability of
/// every 256 ms given by Silero, which tells a voice from a click or the hum of a room.
public struct SegmentSignal: Codable, Equatable, Sendable {
    public static let levelFrameDuration: TimeInterval = 0.02
    /// Silero's step in FluidAudio: 4096 samples at 16 kHz.
    public static let speechFrameDuration: TimeInterval = 0.256
    /// Silero's default of 0.5 misses a whisper; 0.4 hears it and still rejects a silent room
    /// (measured by Hex on recorded meetings).
    public static let speechThreshold: Float = 0.4
    /// Utterance times from the recognizer are not exact to the frame: speech this close counts.
    public static let speechTolerance: TimeInterval = 0.5

    /// The level of each 20 ms frame in half dB below full scale (0 is 0 dBFS, 200 is -100).
    private var levelSteps: Data
    /// The speech probability of each 256 ms frame, times 255. `nil` when no detector was available.
    private var speechSteps: Data?

    /// `levels` in dBFS per 20 ms, `speech` from 0 to 1 per 256 ms.
    public init(levels: [Float], speech: [Float]?) {
        levelSteps = Data(levels.map { UInt8(clamping: Int((-$0 * 2).rounded())) })
        speechSteps = speech.map { Data($0.map { UInt8(clamping: Int(($0 * 255).rounded())) }) }
    }

    /// The levels in dBFS, one per 20 ms from the start of the Segment.
    public var levels: [Float] {
        levelSteps.map { -Float($0) / 2 }
    }

    public var hasSpeechProbabilities: Bool { speechSteps != nil }

    /// Whether Silero heard speech between `start` and `end`, in seconds from the start of the
    /// Segment; `nil` when it did not run.
    public func hasSpeech(from start: TimeInterval, to end: TimeInterval) -> Bool? {
        guard let speechSteps else { return nil }
        let first = max(0, Int(((start - Self.speechTolerance) / Self.speechFrameDuration).rounded(.down)))
        let last = min(speechSteps.count - 1, Int(((end + Self.speechTolerance) / Self.speechFrameDuration).rounded(.down)))
        guard first <= last else { return false }
        let threshold = UInt8((Self.speechThreshold * 255).rounded())
        return speechSteps[(speechSteps.startIndex + first)...(speechSteps.startIndex + last)].contains { $0 >= threshold }
    }

    /// The level of every 20 ms of `samples`, in dBFS; a last partial frame is dropped.
    public static func frameLevels(of samples: [Float], sampleRate: Double) -> [Float] {
        let frame = Int(levelFrameDuration * sampleRate)
        guard frame > 0 else { return [] }
        return samples.withUnsafeBufferPointer { buffer in
            stride(from: 0, to: buffer.count - frame + 1, by: frame).map { start in
                var meanSquare: Float = 0
                vDSP_measqv(buffer.baseAddress! + start, 1, &meanSquare, vDSP_Length(frame))
                return 10 * log10(meanSquare + 1e-10)
            }
        }
    }
}
