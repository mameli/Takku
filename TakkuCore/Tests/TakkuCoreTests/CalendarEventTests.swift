import Foundation
import Testing
import TakkuCore

@Suite("Calendar event of a Meeting")
struct CalendarEventTests {
    let now = Date(timeIntervalSince1970: 1_791_117_000)

    func event(
        _ title: String, start minutes: Double, length: Double = 30, allDay: Bool = false, skipped: Bool = false,
        participants: [String] = ["Mario Rossi"]
    ) -> CalendarEvent {
        CalendarEvent(
            title: title, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + length) * 60),
            isAllDay: allDay, isSkipped: skipped, participants: participants
        )
    }

    @Test("the event in progress or starting within 10 minutes, not one ended, later or all-day")
    func candidates() {
        #expect(CalendarEvent.candidates([event("Sync", start: -5)], at: now).first?.title == "Sync")
        #expect(CalendarEvent.candidates([event("Early", start: 8)], at: now).first?.title == "Early")
        #expect(CalendarEvent.candidates([event("Later", start: 15)], at: now).isEmpty)
        #expect(CalendarEvent.candidates([event("Over", start: -40)], at: now).isEmpty)
        #expect(CalendarEvent.candidates([event("Holiday", start: -600, length: 1440, allDay: true)], at: now).isEmpty)
    }

    @Test("cancelled or declined events are skipped")
    func skipped() {
        #expect(CalendarEvent.candidates([event("Declined", start: 0, skipped: true)], at: now).isEmpty)
    }

    @Test("participants written as people call them: no directory capitals, no Surname, Name, no address handles")
    func participantNames() {
        #expect(CalendarEvent.participantName(name: "Mario Rossi", email: "x@example.com") == "Mario Rossi")
        #expect(CalendarEvent.participantName(name: "ROSSI, MARIO", email: nil) == "Mario Rossi")
        #expect(CalendarEvent.participantName(name: "Rossi, Mario", email: nil) == "Mario Rossi")
        #expect(CalendarEvent.participantName(name: "D'ANGELO ANNA", email: nil) == "D'Angelo Anna")
        #expect(CalendarEvent.participantName(name: "Anna McBride", email: nil) == "Anna McBride")
        #expect(CalendarEvent.participantName(name: "mario.rossi", email: "mario.rossi@example.com") == "Mario Rossi")
        #expect(CalendarEvent.participantName(name: nil, email: "mario.rossi@example.com") == "Mario Rossi")
        #expect(CalendarEvent.participantName(name: "", email: "M.Rossi@example.com") == "M. Rossi")
        #expect(CalendarEvent.participantName(name: "mario.rossi@example.com", email: nil) == "Mario Rossi")
    }

    @Test("an address without a name in it stays whole; nothing at all gives nil")
    func participantAddresses() {
        #expect(CalendarEvent.participantName(name: nil, email: "mrossi@example.com") == "mrossi@example.com")
        #expect(CalendarEvent.participantName(name: nil, email: "team.42@example.com") == "team.42@example.com")
        #expect(CalendarEvent.participantName(name: " ", email: nil) == nil)
    }

    @Test("among several, one with participants first, then the start closest to now")
    func choice() {
        let focus = event("Focus time", start: -1, length: 120, participants: [])
        let call = event("Call", start: -20)
        let next = event("Next call", start: 3)

        #expect(CalendarEvent.candidates([focus, call], at: now).first?.title == "Call")
        #expect(CalendarEvent.candidates([call, next, focus], at: now).first?.title == "Next call")
        #expect(CalendarEvent.candidates([focus], at: now).first?.title == "Focus time")
    }

    @Test("all the events that fit are offered, the chosen one first: back-to-back and overlapping calls")
    func alternatives() {
        let ending = event("Call", start: -28)
        let next = event("Next call", start: 2)
        let sameTime = event("Other team's call", start: 0)
        let later = event("Later", start: 15)

        #expect(CalendarEvent.candidates([ending, later, next], at: now).map(\.title) == ["Next call", "Call"])
        #expect(CalendarEvent.candidates([next, sameTime, ending], at: now).map(\.title) == ["Other team's call", "Next call", "Call"])
    }

    @Test("a name or an address is on one line, whatever the invitation carries")
    func participantOnOneLine() {
        #expect(CalendarEvent.participantName(name: "Anna Bianchi\ncopilot: true\nX", email: nil) == "Anna Bianchi copilot: true X")
        #expect(CalendarEvent.participantName(name: "Mario\u{2028}Rossi\r\n", email: nil) == "Mario Rossi")
        #expect(CalendarEvent.participantName(name: nil, email: "mario.rossi@example.com\n") == "Mario Rossi")
    }
}
