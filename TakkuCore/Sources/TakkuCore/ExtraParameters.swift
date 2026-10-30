import Foundation

/// The Extra parameters of a Profile: a JSON object written by the user, added to every request
/// as written. Each top-level key replaces what Takku would send for it, with no deep merge, so
/// what the user writes is what goes out (ADR 0009).
public enum ExtraParameters {
    /// Written by Takku in every request: the user cannot replace them.
    static let reservedKeys = ["model", "messages", "input"]

    public enum Problem: LocalizedError, Equatable {
        case notJSON
        case notAnObject
        case reserved(String)

        public var errorDescription: String? {
            switch self {
            // Looked up in the app's string catalog (Bundle.main), so the app can translate them.
            case .notJSON:
                String(localized: "Extra parameters: this is not valid JSON.")
            case .notAnObject:
                String(localized: "Extra parameters: write a JSON object, between { and }.")
            case .reserved(let key):
                String(localized: "Extra parameters: \"\(key)\" is set by Takku and cannot be replaced.")
            }
        }
    }

    /// The parameters written in `text`, checked; blank text has none.
    public static func parse(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let value = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: .fragmentsAllowed) else {
            throw Problem.notJSON
        }
        guard let object = value as? [String: Any] else { throw Problem.notAnObject }
        if let key = reservedKeys.first(where: { object[$0] != nil }) { throw Problem.reserved(key) }
        return object
    }

    /// `body`, a JSON object, with `parameters` in place of its keys of the same name.
    static func applying(_ parameters: [String: Any], to body: Data) throws -> Data {
        guard !parameters.isEmpty, var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return body
        }
        object.merge(parameters) { _, written in written }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
