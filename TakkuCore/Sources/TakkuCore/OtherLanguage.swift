import Foundation
import NaturalLanguage

/// Hesitations Parakeet writes out: macOS's recogniser takes them for Portuguese or German.
private let fillers: Set<String> = ["uh", "um", "uhm", "mm", "hmm", "mhm", "eh", "ehm", "ah", "oh"]

/// One word says too little about its language ("okej", "nul"): such replies are kept.
private let minimumWords = 2

/// Below this the Meeting languages together are practically ruled out. In 7 hours of real
/// Meetings in Italian and English it drops Parakeet's sentences in Slovak, German or Russian on
/// faint audio, and keeps Italian ones the recogniser mistakes for Portuguese ("Vai continua
/// Gabriele.", 0.03).
private let maximumMeetingProbability = 0.01

/// True when Parakeet wrote a sentence in a language the Meeting cannot be in (one not in
/// `meetingLanguages`): on faint or unclear audio it can switch language and make up words.
/// Whisper is held to the Meeting language and does not need this.
public func isInAnotherLanguage(_ text: String, meetingLanguages: [String]) -> Bool {
    let words = words(of: text)
    guard words.count >= minimumWords else { return false }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(words.joined(separator: " "))
    let hypotheses = recognizer.languageHypotheses(withMaximum: 100)
    guard let top = hypotheses.max(by: { $0.value < $1.value }), !meetingLanguages.contains(top.key.rawValue) else {
        return false
    }
    let meeting = meetingLanguages.reduce(0) { $0 + (hypotheses[NLLanguage($1)] ?? 0) }
    return meeting < maximumMeetingProbability
}

/// Below this many words, the sentences dropped from a Segment say too little to tell a meeting
/// in another language from made-up sentences.
private let minimumWordsInUntickedLanguage = 40

/// The share of the dropped words (by sentence) that must be in the same language.
private let minimumAgreement = 0.7

/// The language a Segment is spoken in, when it is not ticked in Settings: the sentences
/// `isInAnotherLanguage` dropped are then real speech, and are kept. They are more words than
/// those kept, at least 40, and mostly in one language Takku offers. Made-up sentences are few,
/// on faint audio, and jump between languages (Slovak, German, Swedish, Russian). `nil` otherwise.
public func untickedLanguage(dropped: [String], kept: [String]) -> String? {
    let droppedWords = dropped.map { words(of: $0).count }
    let total = droppedWords.reduce(0, +)
    guard total >= minimumWordsInUntickedLanguage, total > kept.map { words(of: $0).count }.reduce(0, +) else { return nil }
    var wordsByLanguage: [String: Int] = [:]
    for (sentence, count) in zip(dropped, droppedWords) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(words(of: sentence).joined(separator: " "))
        if let language = recognizer.dominantLanguage?.rawValue { wordsByLanguage[language, default: 0] += count }
    }
    guard let (language, count) = wordsByLanguage.max(by: { $0.value < $1.value }),
          MeetingLanguages.offered.contains(language), Double(count) >= minimumAgreement * Double(total)
    else { return nil }
    return language
}

/// The words of a sentence, lowercased, without hesitations or numbers.
private func words(of text: String) -> [String] {
    text.split { $0.isWhitespace || $0.isPunctuation && $0 != "'" }
        .map { $0.lowercased() }
        .filter { word in word.contains(where: \.isLetter) && !fillers.contains(word) }
}
