import Foundation

/// How long the audio of a Meeting is kept, 7 days unless the user chooses otherwise, forever
/// included. The Transcript stays in the Vault forever.
public enum Retention {
    public static let days = 7

    public struct Item: Sendable {
        public let takkuID: UUID
        public let startedAt: Date
        public let status: ProcessingRecord.Status

        public init(takkuID: UUID, startedAt: Date, status: ProcessingRecord.Status) {
            self.takkuID = takkuID
            self.startedAt = startedAt
            self.status = status
        }
    }

    /// Recordings to delete: older than `days` days and already concluded (processed or
    /// failed). Those still pending are kept. `nil` days: the audio is kept forever.
    public static func expired(_ items: [Item], now: Date, days: Int? = days) -> [UUID] {
        guard let days else { return [] }
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        return items
            .filter { $0.startedAt < limit && !$0.status.isPending }
            .map(\.takkuID)
    }
}
