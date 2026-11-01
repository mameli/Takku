import Foundation
import Testing
import TakkuCore

@Suite("What a Segment's audio says beyond its words")
struct SegmentSignalTests {
    /// Speech probabilities per 256 ms: speech from 2.56 to 3.84 seconds only.
    let speech: [Float] = (0..<40).map { (10..<15).contains($0) ? 0.9 : 0.05 }

    @Test("levels survive the cache in half-dB steps")
    func levelsRoundTrip() throws {
        let signal = SegmentSignal(levels: [-12.3, -60, -100, -140], speech: nil)
        let decoded = try JSONDecoder().decode(SegmentSignal.self, from: JSONEncoder().encode(signal))

        #expect(decoded.levels == [-12.5, -60, -100, -127.5])
    }

    @Test("frame levels are the RMS of every 20 ms in dBFS")
    func frameLevels() {
        let samples = [Float](repeating: 0.1, count: 320) + [Float](repeating: 0, count: 320) + [0.5]
        let levels = SegmentSignal.frameLevels(of: samples, sampleRate: 16_000)

        #expect(levels.count == 2)
        #expect(abs(levels[0] - -20) < 0.01)
        #expect(levels[1] == -100)
    }

    @Test("an Utterance where Silero heard no speech is made up; one with speech, or near it, stays")
    func unspokenRemoved() {
        let signal = SegmentSignal(levels: [], speech: speech)
        let spoken = Utterance(track: .me, start: 302.7, end: 303.5, text: " Sì, va bene.")
        let nearSpeech = Utterance(track: .me, start: 304.1, end: 304.6, text: " Certo.")
        let madeUp = Utterance(track: .me, start: 307, end: 308, text: " Ci vediamo alla prossima.")

        #expect(removingUnspoken([spoken, nearSpeech, madeUp], signal: signal, segmentStart: 300) == [spoken, nearSpeech])
    }

    @Test("without speech probabilities every Utterance stays")
    func noDetector() {
        let utterance = Utterance(track: .others, start: 7, end: 8, text: " Grazie a tutti.")

        #expect(removingUnspoken([utterance], signal: SegmentSignal(levels: [], speech: nil), segmentStart: 0) == [utterance])
        #expect(removingUnspoken([utterance], signal: nil, segmentStart: 0) == [utterance])
    }
}
