import Foundation

/// The Model Context Protocol server behind `Takku mcp`: JSON-RPC 2.0, one message per line on
/// stdin and stdout, with three read-only tools over the `MeetingLibrary`. An agent (Claude Code,
/// Claude Desktop…) starts it as a subprocess; it reads the notes folder and never writes.
public struct MCPServer: Sendable {
    public static let protocolVersion = "2025-06-18"
    /// Protocol versions the server answers with the client's own.
    static let supportedVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]

    private let library: MeetingLibrary?
    private let version: String

    /// `library` is `nil` when no notes folder is chosen: every tool then says so.
    public init(library: MeetingLibrary?, version: String) {
        self.library = library
        self.version = version
    }

    /// Answers every line of `input` until it ends, writing each answer as one line.
    public func run(readLine: () -> String?, write: (String) -> Void) {
        while let line = readLine() {
            if let answer = answer(toLine: line) { write(answer) }
        }
    }

    /// The answer to one JSON-RPC message, `nil` for a notification.
    public func answer(toLine line: String) -> String? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = message["id"] else { return nil }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        let response: [String: Any]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? Self.protocolVersion
            response = ["result": [
                "protocolVersion": Self.supportedVersions.contains(requested) ? requested : Self.protocolVersion,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "takku", "version": version],
                "instructions": """
                    The user's meetings recorded with Takku: a Meeting note per meeting (summary, personal \
                    notes, participants) and its Transcript, with who spoke ("Me", "Speaker N" or the name \
                    the user gave). Use search_meetings to find what was said about something, \
                    list_meetings to browse by date, get_meeting to read one in full.
                    """,
            ]]
        case "ping":
            response = ["result": [:] as [String: Any]]
        case "tools/list":
            response = ["result": ["tools": Self.tools]]
        case "tools/call":
            response = ["result": call(params["name"] as? String ?? "", arguments: params["arguments"] as? [String: Any] ?? [:])]
        default:
            response = ["error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
        return Self.encode(response.merging(["jsonrpc": "2.0", "id": id]) { $1 })
    }

    // MARK: - Tools

    static var tools: [[String: Any]] { [
        [
            "name": "list_meetings",
            "description": "Lists the user's meetings, newest first: id, title, date, duration, folder, invited participants, named speakers.",
            "inputSchema": schema([
                "from": ["type": "string", "description": "Earliest date, YYYY-MM-DD."],
                "to": ["type": "string", "description": "Latest date, YYYY-MM-DD."],
                "query": ["type": "string", "description": "Only meetings whose title, folder, participants or speakers contain this text."],
                "limit": ["type": "integer", "description": "At most this many (default 30)."],
            ]),
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "search_meetings",
            "description": "Finds the meetings whose summary, notes or transcript contain every word of the query (case and accents ignored), with the matching lines.",
            "inputSchema": schema([
                "query": ["type": "string", "description": "Words to look for."],
                "limit": ["type": "integer", "description": "At most this many meetings (default 10)."],
            ], required: ["query"]),
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "get_meeting",
            "description": "Reads one meeting: its Meeting note (summary and personal notes) and, unless turned off, its whole transcript.",
            "inputSchema": schema([
                "id": ["type": "string", "description": "The meeting id from list_meetings or search_meetings."],
                "include_transcript": ["type": "boolean", "description": "Default true."],
            ], required: ["id"]),
            "annotations": ["readOnlyHint": true],
        ],
    ] }

    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    private func call(_ name: String, arguments: [String: Any]) -> [String: Any] {
        guard let library else {
            return Self.toolResult("No notes folder is chosen in Takku: set one in Settings → Notes.", isError: true)
        }
        switch name {
        case "list_meetings":
            let from = arguments["from"] as? String, to = arguments["to"] as? String
            let query = (arguments["query"] as? String).map(Self.folded)
            let limit = Self.limit(arguments["limit"], default: 30)
            let meetings = library.meetings().filter { meeting in
                let day = meeting.date.map { String($0.prefix(10)) } ?? ""
                if let from, day < from { return false }
                if let to, day > to { return false }
                guard let query else { return true }
                return Self.folded(([meeting.title, meeting.folder] + meeting.participants + meeting.speakers).joined(separator: "\n"))
                    .contains(query)
            }
            return Self.toolResult(Self.json(meetings.prefix(limit).map(Self.summary)))
        case "search_meetings":
            guard let query = arguments["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                return Self.toolResult("The query is empty.", isError: true)
            }
            let matches = library.search(query).prefix(Self.limit(arguments["limit"], default: 10))
            return Self.toolResult(Self.json(matches.map { match in
                Self.summary(match.meeting).merging(["occurrences": match.occurrences, "lines": match.lines]) { $1 }
            }))
        case "get_meeting":
            guard let idText = arguments["id"] as? String, let id = UUID(uuidString: idText) else {
                return Self.toolResult("The id is not a meeting id: use one from list_meetings.", isError: true)
            }
            guard let meeting = library.meetings().first(where: { $0.id == id }) else {
                return Self.toolResult("No meeting with id \(idText).", isError: true)
            }
            return Self.toolResult(Self.fullText(meeting, includeTranscript: arguments["include_transcript"] as? Bool ?? true))
        default:
            return Self.toolResult("Unknown tool: \(name).", isError: true)
        }
    }

    private static func summary(_ meeting: MeetingLibrary.Meeting) -> [String: Any] {
        var fields: [String: Any] = [
            "id": meeting.id.uuidString, "title": meeting.title, "folder": meeting.folder,
            "has_transcript": meeting.transcript != nil,
        ]
        fields["date"] = meeting.date
        fields["duration"] = meeting.duration
        fields["language"] = meeting.language
        if !meeting.participants.isEmpty { fields["participants"] = meeting.participants }
        if !meeting.speakers.isEmpty { fields["speakers"] = meeting.speakers }
        return fields
    }

    private static func fullText(_ meeting: MeetingLibrary.Meeting, includeTranscript: Bool) -> String {
        var parts = ["# \(meeting.title)", "Meeting note (\(meeting.note.path(percentEncoded: false))):",
                     (try? String(contentsOf: meeting.note, encoding: .utf8)) ?? "(unreadable)"]
        if includeTranscript {
            if let transcript = meeting.transcript {
                parts += ["Transcript (\(transcript.path(percentEncoded: false))):",
                          (try? String(contentsOf: transcript, encoding: .utf8)) ?? "(unreadable)"]
            } else {
                parts.append("No Transcript in the notes folder.")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func limit(_ value: Any?, default fallback: Int) -> Int {
        min(max((value as? Int) ?? fallback, 1), 200)
    }

    private static func toolResult(_ text: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private static func json(_ value: Any) -> String {
        encode(value, pretty: true)
    }

    private static func encode(_ value: Any, pretty: Bool = false) -> String {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
