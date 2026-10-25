import Foundation
import Testing
import TakkuCore

@Suite("Recording retention")
struct RetentionTests {
    let now = Date(timeIntervalSince1970: 1_791_117_000)
    let day: TimeInterval = 86_400

    func item(_ daysAgo: Double, _ status: ProcessingRecord.Status) -> Retention.Item {
        Retention.Item(takkuID: UUID(), startedAt: now.addingTimeInterval(-daysAgo * day), status: status)
    }

    @Test("after 7 days Recordings that are processed or failed are deleted, never the ones still pending")
    func expired() {
        let oldCompleted = item(8, .completed)
        let oldFailed = item(10, .failed(reason: "401"))
        let recentCompleted = item(6.9, .completed)
        let oldQueued = item(9, .queued)
        let oldProcessing = item(9, .processing)
        let oldRecording = item(9, .recording)
        let oldRegenerating = item(9, .regenerating)

        let expired = Retention.expired(
            [oldCompleted, oldFailed, recentCompleted, oldQueued, oldProcessing, oldRecording, oldRegenerating],
            now: now
        )

        #expect(Set(expired) == [oldCompleted.takkuID, oldFailed.takkuID])
    }

    @Test("the number of retention days can be changed")
    func customDays() {
        let twoDaysOld = item(2, .completed)

        #expect(Retention.expired([twoDaysOld], now: now, days: 1) == [twoDaysOld.takkuID])
        #expect(Retention.expired([twoDaysOld], now: now, days: 3).isEmpty)
    }

    @Test("kept forever, no audio ever expires")
    func forever() {
        let yearOld = item(365, .completed)

        #expect(Retention.expired([yearOld], now: now, days: nil).isEmpty)
    }
}
