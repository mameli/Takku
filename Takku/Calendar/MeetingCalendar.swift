import EventKit
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "calendar")

/// The calendar event a Meeting is for, read from the Mac's calendars when the user turned it on
/// in Settings. EventKit reads the calendars on the Mac: nothing is sent anywhere.
enum MeetingCalendar {
    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Asks macOS for access to the calendars; the first time it shows the prompt.
    static func requestAccess() async -> Bool {
        do {
            return try await EKEventStore().requestFullAccessToEvents()
        } catch {
            logger.error("Calendar access request failed: \(error.logCode, privacy: .public) \(error, privacy: .private)")
            return false
        }
    }

    /// The events a Meeting starting now can be for, the likeliest first (see
    /// `CalendarEvent.candidates`); none if the calendar is off or not allowed.
    static func eventsInProgress(at now: Date) -> [CalendarEvent] {
        guard AppSettings.useCalendar, isAuthorized else { return [] }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(
            withStart: now, end: now.addingTimeInterval(CalendarEvent.earlyStart), calendars: nil
        )
        let events = store.events(matching: predicate).map { event in
            let declined = event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
            return CalendarEvent(
                title: event.title ?? "",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                isSkipped: event.status == .canceled || declined,
                participants: (event.attendees ?? []).compactMap(participantName)
            )
        }
        return CalendarEvent.candidates(events, at: now)
    }

    /// The name of a person invited, or their email without one, made readable
    /// (`CalendarEvent.participantName`); `nil` for the user, rooms, resources and groups
    /// (distribution lists say nothing about who is in the call).
    private static func participantName(_ participant: EKParticipant) -> String? {
        guard !participant.isCurrentUser,
              ![.room, .resource, .group].contains(participant.participantType)
        else { return nil }
        let address = participant.url.absoluteString
        return CalendarEvent.participantName(
            name: participant.name,
            email: address.hasPrefix("mailto:") ? String(address.dropFirst("mailto:".count)) : nil
        )
    }
}
