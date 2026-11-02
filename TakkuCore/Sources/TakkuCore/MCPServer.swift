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
            let meetings = library.meetings(
                from: arguments["from"] as? String, to: arguments["to"] as? String, matching: arguments["query"] as? String
            )
            return Self.toolResult(Self.json(meetings.prefix(Self.limit(arguments["limit"], default: 30)).map(\.fields)))
        case "search_meetings":
            guard let query = arguments["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                return Self.toolResult("The query is empty.", isError: true)
            }
            let matches = library.search(query).prefix(Self.limit(arguments["limit"], default: 10))
            return Self.toolResult(Self.json(matches.map { match in
                match.meeting.fields.merging(["occurrences": match.occurrences, "lines": match.lines]) { $1 }
            }))
        case "get_meeting":
            guard let idText = arguments["id"] as? String, let id = UUID(uuidString: idText) else {
                return Self.toolResult("The id is not a meeting id: use one from list_meetings.", isError: true)
            }
            guard let meeting = library.meeting(id: id) else {
                return Self.toolResult("No meeting with id \(idText).", isError: true)
            }
            return Self.toolResult(meeting.text(includeTranscript: arguments["include_transcript"] as? Bool ?? true))
        default:
            return Self.toolResult("Unknown tool: \(name).", isError: true)
        }
    }

    static func limit(_ value: Any?, default fallback: Int) -> Int {
        min(max((value as? Int) ?? fallback, 1), 200)
    }

    private static func toolResult(_ text: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    static func json(_ value: Any) -> String {
        encode(value, pretty: true)
    }

    private static func encode(_ value: Any, pretty: Bool = false) -> String {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

}
