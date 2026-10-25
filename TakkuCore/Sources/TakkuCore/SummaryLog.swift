import Foundation

/// The Summary log: every request Takku sends the model for a Summary, and every reply, as they
/// went, one file (entry) per Summary in `~/.takku/summary-log/`. The user reads it to improve
/// the Templates; Takku writes it and never reads it back (ADR 0010).
public enum SummaryLog {
    /// Past this size the oldest entries are deleted: tens of Meetings of an hour.
    public static let limitBytes = 5_000_000

    /// One request to the model and what came back.
    public struct Call: Sendable, Equatable {
        public enum Kind: String, Sendable {
            /// The whole Transcript in one request.
            case single
            /// A block of a Transcript too long for the context.
            case partial
            /// Partial summaries merged in a group, for very long Meetings.
            case group
            /// The partial summaries merged into the Summary.
            case merge
            /// A block of the Transcript rewritten in full with a full-text Template.
            case block
            /// The title for the note's rename.
            case title
        }

        public let kind: Kind
        /// The request body as sent: model, messages, reasoning, Extra parameters. Never the
        /// address or the API key, which are not in it.
        public let request: Data
        /// The reply body as received; `nil` if none came (timeout, no connection).
        public let response: Data?
        public let status: Int?
        public let seconds: Double
        /// Why the request failed before a reply came.
        public let error: String?

        public init(kind: Kind, request: Data, response: Data?, status: Int?, seconds: Double, error: String?) {
            self.kind = kind
            self.request = request
            self.response = response
            self.status = status
            self.seconds = seconds
            self.error = error
        }
    }

    /// The calls of one Summary, in the order they were made.
    public actor Recorder {
        public private(set) var calls: [Call] = []

        public init() {}

        func append(_ call: Call) {
            calls.append(call)
        }
    }

    public struct Entry: Sendable {
        public let takkuID: UUID
        /// The Meeting note's name when the Summary was written.
        public let meetingNote: String
        public let meetingStartedAt: Date
        public let template: String
        public let profile: ProviderProfile
        /// Why the Summary was not written; `nil` if it was.
        public let error: String?
        public let calls: [Call]
        public let writtenAt: Date

        public init(
            takkuID: UUID, meetingNote: String, meetingStartedAt: Date, template: String, profile: ProviderProfile,
            error: String?, calls: [Call], writtenAt: Date
        ) {
            self.takkuID = takkuID
            self.meetingNote = meetingNote
            self.meetingStartedAt = meetingStartedAt
            self.template = template
            self.profile = profile
            self.error = error
            self.calls = calls
            self.writtenAt = writtenAt
        }

        /// `2026-10-20 1722 - Notes - claude-haiku-5.5`: when, with which Template and which model
        /// (without the provider's prefix), without `.json`.
        public func fileName(timeZone: TimeZone = .current) -> String {
            let model = profile.model.split(separator: "/").last.map(String.init) ?? profile.model
            let name = "\(DateFormatter.posix("yyyy-MM-dd HHmm", timeZone: timeZone).string(from: writtenAt)) - \(template) - \(model)"
            return VaultNaming.fileName(name) ?? name
        }

        /// The entry as indented JSON: `about` first, opening with an empty `comment` for the user
        /// to fill in by hand, then `calls`, each with its bodies as they went (as a string when a
        /// reply is not JSON).
        public func json(timeZone: TimeZone = .current) throws -> Data {
            let dates = ISO8601DateFormatter()
            dates.timeZone = timeZone
            var about: [String: Any] = [
                "comment": "",
                "takku_id": takkuID.uuidString,
                "meeting_note": meetingNote,
                "meeting_started_at": dates.string(from: meetingStartedAt),
                "written_at": dates.string(from: writtenAt),
                "template": template,
                "profile": profile.displayName,
                // Never the address, as in the logs: it can name a company.
                "place": profile.runsOnThisMac ? "on this Mac" : "remote",
                "model": profile.model,
            ]
            about["error"] = error
            let calls = self.calls.map { call -> [String: Any] in
                var object: [String: Any] = [
                    "kind": call.kind.rawValue,
                    "seconds": (call.seconds * 10).rounded() / 10,
                    "request": Self.body(call.request),
                ]
                object["response"] = call.response.map(Self.body)
                object["status"] = call.status
                object["error"] = call.error
                return object
            }
            // Sorted keys: the same entry gives the same file, and "about" comes before "calls".
            return try JSONSerialization.data(
                withJSONObject: ["about": about, "calls": calls], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        }

        private static func body(_ data: Data) -> Any {
            (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) ?? String(decoding: data, as: UTF8.self)
        }
    }

    /// An entry already on disk.
    public struct StoredEntry: Sendable {
        public let url: URL
        public let bytes: Int
        public let writtenAt: Date

        public init(url: URL, bytes: Int, writtenAt: Date) {
            self.url = url
            self.bytes = bytes
            self.writtenAt = writtenAt
        }
    }

    /// The entries to delete so the log stays within `limit`: the oldest ones. The newest is kept
    /// even when it alone is over the limit.
    public static func overLimit(_ entries: [StoredEntry], limit: Int = limitBytes) -> [URL] {
        var total = 0
        var deleted: [URL] = []
        for (index, entry) in entries.sorted(by: { $0.writtenAt > $1.writtenAt }).enumerated() {
            total += entry.bytes
            if index > 0 && total > limit { deleted.append(entry.url) }
        }
        return deleted
    }
}
