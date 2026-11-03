import Testing
import TakkuCore

@Suite("A Meeting left recording")
struct LongRecordingTests {
    @Test("no reminder in the first two hours")
    func noReminderAtFirst() {
        #expect(LongRecording.reminderHours(elapsed: 0, reminded: 0) == nil)
        #expect(LongRecording.reminderHours(elapsed: 2 * 3600 - 1, reminded: 0) == nil)
    }

    @Test("a reminder at two hours, then one every hour, each once")
    func everyHour() {
        #expect(LongRecording.reminderHours(elapsed: 2 * 3600, reminded: 0) == 2)
        #expect(LongRecording.reminderHours(elapsed: 2 * 3600 + 600, reminded: 2) == nil)
        #expect(LongRecording.reminderHours(elapsed: 3 * 3600, reminded: 2) == 3)
    }

    @Test("after a night asleep one reminder with all the hours, not one per hour missed")
    func afterSleep() {
        #expect(LongRecording.reminderHours(elapsed: 14 * 3600 + 120, reminded: 3) == 14)
    }

    @Test("half an hour transcribed without anyone speaking stops the Meeting")
    func silence() {
        #expect(LongRecording.nobodySpeaks(lastSpeech: 600, transcribedUntil: 600 + 30 * 60))
        #expect(!LongRecording.nobodySpeaks(lastSpeech: 600, transcribedUntil: 600 + 29 * 60))
        #expect(LongRecording.nobodySpeaks(lastSpeech: nil, transcribedUntil: 30 * 60))
        #expect(!LongRecording.nobodySpeaks(lastSpeech: nil, transcribedUntil: 25 * 60))
    }
}
