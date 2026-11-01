import Testing
import TakkuCore

@Suite("Call start and end")
struct CallWatchTests {
    let zoom = CallApp(name: "zoom.us", bundleID: "us.zoom.xos")
    let teams = CallApp(name: "Microsoft Teams", bundleID: "com.microsoft.teams2")
    let chrome = CallApp(name: "Google Chrome", bundleID: "com.google.Chrome")
    let handy = CallApp(name: "Handy", bundleID: "com.pais.handy")

    /// Feeds the watch every 3 seconds from `from` to `to` and returns what it suggested, with when.
    func run(
        _ watch: inout CallWatch, apps: Set<CallApp>, recording: Bool, from: Double, to: Double
    ) -> [(Double, CallWatch.Suggestion)] {
        stride(from: from, through: to, by: 3).compactMap { now in
            watch.update(appsUsingInput: apps, isRecording: recording, now: now).map { (now, $0) }
        }
    }

    @Test("an app on the microphone for 15 seconds suggests a start, once per stretch of use")
    func start() {
        var watch = CallWatch()
        let suggestions = run(&watch, apps: [chrome], recording: false, from: 0, to: 60)

        #expect(suggestions.map(\.1) == [.start(app: "Google Chrome")])
        #expect(suggestions.first?.0 == 15)
    }

    @Test("a call app is suggested after 5 seconds")
    func callAppSooner() {
        var watch = CallWatch()
        let suggestions = run(&watch, apps: [zoom], recording: false, from: 0, to: 60)

        #expect(suggestions.map(\.1) == [.start(app: "zoom.us")])
        #expect(suggestions.first?.0 == 6)
    }

    @Test("a short use of the microphone suggests nothing")
    func shortUse() {
        var watch = CallWatch()
        #expect(run(&watch, apps: [chrome], recording: false, from: 0, to: 12).isEmpty)
        #expect(run(&watch, apps: [], recording: false, from: 15, to: 30).isEmpty)
        #expect(run(&watch, apps: [chrome], recording: false, from: 33, to: 45).isEmpty)
    }

    @Test("an app that is not for calls, like a dictation app, is never suggested, however long it listens")
    func dictationIgnored() {
        var watch = CallWatch()
        #expect(run(&watch, apps: [handy], recording: false, from: 0, to: 300).isEmpty)
    }

    @Test("while recording, a dictation app on the microphone does not hold off the stop suggestion")
    func dictationDoesNotHoldTheCall() {
        var watch = CallWatch()
        _ = run(&watch, apps: [zoom], recording: true, from: 0, to: 60)
        #expect(run(&watch, apps: [handy], recording: true, from: 63, to: 120).map(\.1) == [.stop])
    }

    @Test("an app back on the microphone within a minute is the same call; after a minute away, a new one")
    func sameCall() {
        var watch = CallWatch()
        #expect(run(&watch, apps: [chrome], recording: false, from: 0, to: 15).map(\.1) == [.start(app: "Google Chrome")])
        _ = run(&watch, apps: [], recording: false, from: 18, to: 27)
        #expect(run(&watch, apps: [chrome], recording: false, from: 30, to: 60).isEmpty)
        _ = run(&watch, apps: [], recording: false, from: 63, to: 123)
        #expect(run(&watch, apps: [chrome], recording: false, from: 126, to: 141).map(\.1) == [.start(app: "Google Chrome")])
    }

    @Test("a gap between updates (the Mac asleep) starts the stretch of use again")
    func gapRestarts() {
        var watch = CallWatch()
        #expect(watch.update(appsUsingInput: [chrome], isRecording: false, now: 0) == nil)
        #expect(watch.update(appsUsingInput: [chrome], isRecording: false, now: 3600) == nil)
        #expect(run(&watch, apps: [chrome], recording: false, from: 3603, to: 3615).map(\.0) == [3615])
    }

    @Test("when the call app lets the microphone go for 30 seconds while recording, a stop is suggested once")
    func stop() {
        var watch = CallWatch()
        _ = run(&watch, apps: [teams], recording: true, from: 0, to: 300)
        let suggestions = run(&watch, apps: [], recording: true, from: 303, to: 600)

        #expect(suggestions.map(\.1) == [.stop])
        #expect(suggestions.first?.0 == 330)
    }

    @Test("a Meeting without any call app on the microphone gets no stop suggestion")
    func noCallNoStop() {
        var watch = CallWatch()
        #expect(run(&watch, apps: [], recording: true, from: 0, to: 600).isEmpty)
    }

    @Test("a call taken back and released again suggests the stop again")
    func stopAgain() {
        var watch = CallWatch()
        _ = run(&watch, apps: [teams], recording: true, from: 0, to: 30)
        #expect(run(&watch, apps: [], recording: true, from: 33, to: 90).map(\.1) == [.stop])
        _ = run(&watch, apps: [teams], recording: true, from: 93, to: 120)
        #expect(run(&watch, apps: [], recording: true, from: 123, to: 200).map(\.1) == [.stop])
    }

    @Test("stopping by hand during a call does not suggest starting again for the same call")
    func stoppedDuringCall() {
        var watch = CallWatch()
        _ = run(&watch, apps: [chrome], recording: true, from: 0, to: 60)

        #expect(run(&watch, apps: [chrome], recording: false, from: 63, to: 200).isEmpty)
    }
}
