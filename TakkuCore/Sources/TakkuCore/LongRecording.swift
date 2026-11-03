import Foundation

/// A Meeting left recording after the call: Takku has no limit on how long one lasts, so it
/// reminds the user every hour from the second, and stops by itself once nobody has spoken for half
/// an hour. A Meeting forgotten for days was recorded and transcribed whole (seen in 1.16).
public enum LongRecording {
    /// The first reminder, in whole hours since the start; then one every hour.
    public static let firstReminderHours = 2
    /// No Utterance on either Track for this long: nobody is in the Meeting any more.
    public static let stopAfterSilence: TimeInterval = 30 * 60

    /// The hours to remind the user of at `elapsed` seconds (the clock's, sleep included), `nil`
    /// when no reminder is due. `reminded` is the hours of the last reminder, 0 before the first.
    public static func reminderHours(elapsed: TimeInterval, reminded: Int) -> Int? {
        let hours = Int(elapsed / 3600)
        return hours >= firstReminderHours && hours > reminded ? hours : nil
    }

    /// Whether to stop: `transcribedUntil` is how far both Tracks are transcribed, `lastSpeech`
    /// the end of the last Utterance in them (`nil` if none), in seconds of recording from the
    /// start. Only what is transcribed counts: while transcription lags behind, nothing stops.
    public static func nobodySpeaks(
        lastSpeech: TimeInterval?, transcribedUntil: TimeInterval, after silence: TimeInterval = stopAfterSilence
    ) -> Bool {
        transcribedUntil - (lastSpeech ?? 0) >= silence
    }
}
