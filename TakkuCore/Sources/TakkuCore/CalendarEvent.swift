import Foundation

/// A calendar event as Takku needs it, read from EventKit by the app.
public struct CalendarEvent: Hashable, Sendable {
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    /// Cancelled, or declined by the user.
    public let isSkipped: Bool
    /// The invited participants, without the user, rooms and resources.
    public let participants: [String]

    public init(title: String, start: Date, end: Date, isAllDay: Bool, isSkipped: Bool, participants: [String]) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isSkipped = isSkipped
        self.participants = participants
    }

    /// How an invited participant is written in the Meeting note: the calendar's name, or the
    /// email without one, made readable. Directories write "ROSSI, MARIO" and some invitations
    /// carry only "mario.rossi": both become "Mario Rossi", the way the others call them in the
    /// Transcript. An address without two words in it ("mrossi@…") stays whole. `nil` without
    /// a name or an email.
    public static func participantName(name: String?, email: String?) -> String? {
        let name = oneLine(name)
        if !name.isEmpty, !name.contains("@") {
            if !name.contains(" "), let handleName = nameFromHandle(name) { return handleName }
            return recased(surnameLast(name))
        }
        let address = name.isEmpty ? oneLine(email) : name
        guard !address.isEmpty else { return nil }
        return nameFromHandle(String(address.prefix { $0 != "@" })) ?? address
    }

    /// The text on one line: every run of spaces, line breaks and control characters becomes one space.
    /// A name or an address comes from an invitation, and the Meeting note is a file of lines.
    static func oneLine(_ text: String?) -> String {
        (text ?? "").components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Rossi, Mario" → "Mario Rossi"; a name with no comma, or more than one, stays as it is.
    private static func surnameLast(_ name: String) -> String {
        let parts = name.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return name }
        return "\(parts[1]) \(parts[0])"
    }

    /// A name all in capitals or all in lower case gets a capital at the start of every word
    /// ("ROSSI" → "Rossi", "D'ANGELO" → "D'Angelo"); one in mixed case stays as it is ("McBride").
    private static func recased(_ name: String) -> String {
        guard !(name.contains(where: \.isUppercase) && name.contains(where: \.isLowercase)) else { return name }
        var result = ""
        var startsWord = true
        for character in name.lowercased() {
            result += startsWord ? character.uppercased() : String(character)
            startsWord = !character.isLetter
        }
        return result
    }

    /// "mario.rossi" or "mario_rossi" → "Mario Rossi", "m.rossi" → "M. Rossi"; `nil` unless the
    /// handle is at least two words of letters only.
    private static func nameFromHandle(_ handle: String) -> String? {
        let words = handle.split(whereSeparator: { $0 == "." || $0 == "_" })
        guard words.count >= 2, words.allSatisfy({ $0.allSatisfy(\.isLetter) }) else { return nil }
        return words.map { word in
            let capitalized = word.prefix(1).uppercased() + word.dropFirst().lowercased()
            return word.count == 1 ? capitalized + "." : capitalized
        }.joined(separator: " ")
    }

    /// A Meeting started this early is still for the event: people join a few minutes before.
    public static let earlyStart: TimeInterval = 10 * 60

    /// The events a Meeting starting `now` can be for, the likeliest first: not all-day, not
    /// cancelled or declined, starting at most 10 minutes from now and not ended yet. First those
    /// with participants, then by the start closest to now. The first one names the note; the
    /// others are offered in the menu, because the time alone cannot tell back-to-back or
    /// overlapping calls apart.
    public static func candidates(_ events: [CalendarEvent], at now: Date) -> [CalendarEvent] {
        events
            .filter { !$0.isAllDay && !$0.isSkipped && $0.start <= now.addingTimeInterval(earlyStart) && $0.end > now }
            .sorted { a, b in
                if a.participants.isEmpty != b.participants.isEmpty { return !a.participants.isEmpty }
                return abs(a.start.timeIntervalSince(now)) < abs(b.start.timeIntervalSince(now))
            }
    }
}
