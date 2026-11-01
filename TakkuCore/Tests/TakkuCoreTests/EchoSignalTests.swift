import Foundation
import Testing
import TakkuCore

/// Synthetic signals, ported with the cases from Hex's `src/meeting/echo.rs` tests.
@Suite("Telling the others' voice from the speakers apart from someone speaking in the room")
struct EchoSignalTests {
    static let rate = 16_000

    /// Deterministic pseudo-speech: noise shaped by syllable-like bursts whose rhythm depends on `seed`.
    static func speech(_ seconds: Float, seed: UInt32) -> [Float] {
        var state = max(seed &* 2_654_435_761, 1)
        func noise() -> Float {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return Float(state) / Float(UInt32.max) * 2 - 1
        }
        let syllable = 0.11 + Float(seed % 7) * 0.013
        return (0..<Int(seconds * Float(rate))).map { index in
            let time = Float(index) / Float(rate)
            let phase = (time / syllable).truncatingRemainder(dividingBy: 1)
            let word = (UInt32((time / (syllable * (3 + Float(seed % 3)))).rounded(.down)) + seed) % 4
            let envelope = word == 0 ? 0.02 : sin(phase * .pi)
            return noise() * 0.2 * envelope
        }
    }

    static func roomNoise(_ count: Int, seed: UInt32) -> [Float] {
        var state = max(seed &* 747_796_405, 1)
        return (0..<count).map { _ in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return (Float(state) / Float(UInt32.max) * 2 - 1) * 0.001
        }
    }

    /// The microphone hears the others `delay` milliseconds later, attenuated.
    static func bleed(_ others: [Float], delay: Int, gain: Float) -> [Float] {
        let offset = delay * rate / 1000
        var me = roomNoise(others.count, seed: 3)
        for (index, sample) in others.enumerated() where index + offset < me.count {
            me[index + offset] += sample * gain
        }
        return me
    }

    /// A muffled, reverberant copy: one-pole low-pass plus a decaying tail.
    static func room(_ others: [Float], delay: Int, gain: Float) -> [Float] {
        var low: Float = 0
        var wet = others.map { sample in
            low += 0.15 * (sample - low)
            return low
        }
        let echo = rate * 35 / 1000
        for index in echo..<wet.count { wet[index] += wet[index - echo] * 0.55 }
        return bleed(wet, delay: delay, gain: gain)
    }

    static func adding(_ speech: [Float], at second: Int, gain: Float, to track: inout [Float]) {
        for (offset, sample) in speech.enumerated() { track[second * rate + offset] += sample * gain }
    }

    static func signal(_ others: [Float], _ me: [Float]) -> EchoSignal {
        EchoSignal(
            others: SegmentSignal.frameLevels(of: others, sampleRate: Double(rate)),
            me: SegmentSignal.frameLevels(of: me, sampleRate: Double(rate))
        )
    }

    @Test("the others' voice from the speakers is bleed")
    func bleedIsBleed() {
        let others = Self.speech(12, seed: 11)
        let signal = Self.signal(others, Self.bleed(others, delay: 60, gain: 0.08))

        #expect(signal.assess(from: 2, to: 5) == .bleed)
        #expect(signal.assess(from: 6, to: 9.5) == .bleed)
    }

    @Test("talking over the others is local")
    func talkingOver() {
        let others = Self.speech(12, seed: 11)
        var me = Self.bleed(others, delay: 60, gain: 0.08)
        Self.adding(Self.speech(3, seed: 29), at: 5, gain: 0.9, to: &me)
        let signal = Self.signal(others, me)

        #expect(signal.assess(from: 5, to: 8) == .local)
        #expect(signal.assess(from: 1, to: 4.5) == .bleed)
    }

    @Test("speaking while the others are silent is local")
    func othersSilent() {
        var others = Self.speech(12, seed: 11)
        others.replaceSubrange((6 * Self.rate)..., with: [Float](repeating: 0, count: others.count - 6 * Self.rate))
        var me = Self.bleed(others, delay: 60, gain: 0.08)
        Self.adding(Self.speech(4, seed: 5), at: 7, gain: 0.5, to: &me)

        #expect(Self.signal(others, me).assess(from: 7.2, to: 10.8) == .local)
    }

    @Test("late, muffled bleed is bleed and speech over it is local")
    func muffledBleed() {
        let others = Self.speech(14, seed: 11)
        var me = Self.room(others, delay: 450, gain: 0.25)
        #expect(Self.signal(others, me).assess(from: 2, to: 5) == .bleed)

        Self.adding(Self.speech(3, seed: 29), at: 7, gain: 0.9, to: &me)
        let signal = Self.signal(others, me)
        #expect(signal.assess(from: 7, to: 10) == .local)
        #expect(signal.assess(from: 2, to: 5) == .bleed)
    }

    @Test("a short phrase inside a long stretch of bleed makes it undecided")
    func shortPhraseInBleed() {
        let others = Self.speech(16, seed: 11)
        var me = Self.bleed(others, delay: 60, gain: 0.08)
        Self.adding(Self.speech(1.2, seed: 29), at: 8, gain: 0.9, to: &me)
        let signal = Self.signal(others, me)

        #expect(signal.assess(from: 1, to: 15) == nil)
        #expect(signal.assess(from: 1, to: 7.5) == .bleed)
    }

    @Test("with headphones every sound of the microphone is local, and silence is undecided")
    func headphones() {
        let others = Self.speech(12, seed: 11)
        var me = Self.roomNoise(others.count, seed: 3)
        Self.adding(Self.speech(3, seed: 17), at: 4, gain: 0.4, to: &me)
        let signal = Self.signal(others, me)

        #expect(signal.assess(from: 4, to: 7) == .local)
        #expect(signal.assess(from: 9, to: 11) == nil)
    }

    @Test("Segments are placed at their start, with silence in between")
    func segmentsPlaced() {
        let others = Self.speech(12, seed: 11)
        let me = Self.bleed(others, delay: 60, gain: 0.08)
        let levels = { (samples: [Float]) in SegmentSignal.frameLevels(of: samples, sampleRate: Double(Self.rate)) }
        let half = 6 * Self.rate
        let signal = EchoSignal(segments: [
            (Segment(track: .others, index: 0, start: 0), levels(Array(others[..<half]))),
            (Segment(track: .others, index: 1, start: 6), levels(Array(others[half...]))),
            (Segment(track: .me, index: 0, start: 0), levels(me)),
        ])

        #expect(signal.assess(from: 6.5, to: 9.5) == .bleed)
    }
}
