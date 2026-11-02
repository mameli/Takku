import Foundation

/// Sentences Whisper makes up on a short noise (a click, a notification sound): it learned
/// them from the end of subtitled videos. Lowercased, without final punctuation.
private let stockSentences: Set<String> = [
    "grazie", "grazie a tutti", "grazie mille", "grazie per la visione", "grazie per l'attenzione",
    "sottotitoli creati dalla comunità amara.org", "sottotitoli a cura di qtss",
    "thank you", "thank you very much", "thanks for watching", "thank you for watching", "you", "bye",
    "danke", "vielen dank", "danke fürs zuschauen", "untertitel der amara.org-community",
    "merci", "merci beaucoup", "merci d'avoir regardé", "sous-titres réalisés par la communauté d'amara.org", "sous-titres réalisés para la communauté d'amara.org",
    "gracias", "muchas gracias", "gracias por ver", "subtítulos realizados por la comunidad de amara.org",
]

/// More sound than this (pauses excluded) is real speech even when the text is a stock sentence.
private let maxHallucinationSeconds: TimeInterval = 3

/// True when everything recognised in a speech range is one stock sentence and the range has
/// little sound in it (`speechDuration`, from `speechSeconds`): a real "Grazie." from the others is lost, a made-up one on a noise no longer appears.
public func isLikelyHallucination(_ texts: [String], speechDuration: TimeInterval) -> Bool {
    guard speechDuration <= maxHallucinationSeconds else { return false }
    let text = texts.joined(separator: " ")
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    return stockSentences.contains(text)
}

/// The Utterances of a Segment starting at `segmentStart` (seconds from the start of the Meeting)
/// in which Silero heard speech: the recognizer also makes up sentences on a click, a cough or
/// room noise loud enough for the speech ranges, not only the stock ones. Without speech
/// probabilities every Utterance is kept.
public func removingUnspoken(_ utterances: [Utterance], signal: SegmentSignal?, segmentStart: TimeInterval) -> [Utterance] {
    utterances.filter { isSpoken($0, signal: signal, segmentStart: segmentStart) }
}

/// False when Silero heard no speech during the Utterance; true without speech probabilities.
public func isSpoken(_ utterance: Utterance, signal: SegmentSignal?, segmentStart: TimeInterval) -> Bool {
    signal?.hasSpeech(from: utterance.start - segmentStart, to: utterance.end - segmentStart) ?? true
}
