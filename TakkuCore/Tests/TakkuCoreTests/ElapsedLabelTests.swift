import Testing
import TakkuCore

@Suite("Timer label")
struct ElapsedLabelTests {
    @Test("under an hour it shows minutes and seconds")
    func minutesAndSeconds() {
        #expect(elapsedLabel(754) == "12:34")
    }

    @Test("minutes and seconds always have two digits", arguments: [
        (0.0, "00:00"),
        (7.0, "00:07"),
        (59.9, "00:59"),
    ])
    func zeroPadded(elapsed: Double, label: String) {
        #expect(elapsedLabel(elapsed) == label)
    }

    @Test("past the hour it adds hours without a leading zero")
    func hours() {
        #expect(elapsedLabel(3723) == "1:02:03")
    }

    @Test("a time that does not fit an Int does not stop the app", arguments: [1e19, 1e300, Double.infinity, Double.nan])
    func outOfRange(elapsed: Double) {
        #expect(elapsedLabel(elapsed) == "00:00")
    }
}
