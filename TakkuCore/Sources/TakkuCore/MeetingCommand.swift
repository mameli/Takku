import Foundation

/// `takku list|search|get|mcp`: the Meetings of the notes folder from a terminal or a script,
/// read only, without starting the app. `mcp` serves the same over MCP (`MCPServer`); the others
/// print readable text, or with `--json` the same JSON the MCP tools answer with.
public struct MeetingCommand: Sendable {
    /// The first arguments that make the app run as a command instead of starting.
    public static let names: Set<String> = ["list", "search", "get", "mcp", "help", "--help", "-h"]

    static let usage = """
        Usage: takku <command> [options]

          list [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--query TEXT] [--limit N]
                              meetings, newest first; --query matches title, folder,
                              participants and speakers
          search WORDS [--limit N]
                              meetings whose note or transcript contains every word
          get ID [--no-transcript]
                              a meeting's note and transcript
          mcp                 serves the meetings to an AI assistant over MCP (stdio)

        Every command takes --notes-folder PATH (default: the one chosen in Takku's Settings);
        list, search and get take --json.
        """

    private let arguments: [String]
    private let notesFolder: String?
    private let version: String

    /// `arguments` without the program name; `notesFolder` is the one chosen in Settings.
    public init(arguments: [String], notesFolder: String?, version: String) {
        self.arguments = arguments
        self.notesFolder = notesFolder
        self.version = version
    }

    /// Runs the command and returns its exit status: 0 done, 1 failed, 2 wrong arguments.
    public func run(
        readLine: () -> String?, output: (String) -> Void, error: (String) -> Void
    ) -> Int32 {
        guard let command = arguments.first, Self.names.contains(command) else {
            error(Self.usage)
            return 2
        }
        if ["help", "--help", "-h"].contains(command) {
            output(Self.usage)
            return 0
        }
        let options: Options
        do {
            options = try Options(Array(arguments.dropFirst()), command: command)
        } catch let failure as Options.Failure {
            error("takku \(command): \(failure.message)\n\n\(Self.usage)")
            return 2
        } catch {
            return 2
        }
        let library = (options.notesFolder ?? notesFolder)
            .map { MeetingLibrary(notesFolder: URL(filePath: $0, directoryHint: .isDirectory)) }
        if command == "mcp" {
            MCPServer(library: library, version: version).run(readLine: readLine, write: output)
            return 0
        }
        guard let library else {
            error("No notes folder is chosen in Takku: set one in Settings, or pass --notes-folder PATH.")
            return 1
        }
        switch command {
        case "list":
            let meetings = library.meetings(from: options.from, to: options.to, matching: options.query)
                .prefix(MCPServer.limit(options.limit, default: 30))
            output(options.json ? MCPServer.json(meetings.map(\.fields)) : meetings.map(Self.line).joined(separator: "\n\n"))
        case "search":
            let matches = library.search(options.words.joined(separator: " "))
                .prefix(MCPServer.limit(options.limit, default: 10))
            if options.json {
                output(MCPServer.json(matches.map { match in
                    match.meeting.fields.merging(["occurrences": match.occurrences, "lines": match.lines]) { $1 }
                }))
            } else {
                output(matches.map { match in
                    ([Self.line(match.meeting)] + match.lines.map { "    > \($0)" }).joined(separator: "\n")
                }
                .joined(separator: "\n\n"))
            }
        default:
            guard let id = UUID(uuidString: options.words[0]) else {
                error("takku get: \(options.words[0]) is not a meeting id: use one from takku list.")
                return 1
            }
            guard let meeting = library.meeting(id: id) else {
                error("takku get: no meeting with id \(options.words[0]).")
                return 1
            }
            if options.json {
                var fields = meeting.fields
                fields["note"] = try? String(contentsOf: meeting.note, encoding: .utf8)
                if options.includeTranscript, let transcript = meeting.transcript {
                    fields["transcript"] = try? String(contentsOf: transcript, encoding: .utf8)
                }
                output(MCPServer.json(fields))
            } else {
                output(meeting.text(includeTranscript: options.includeTranscript))
            }
        }
        return 0
    }

    /// "2026-10-20 10:00 · Retrospettiva sprint 12 · 45m · Archive" and the id under it.
    static func line(_ meeting: MeetingLibrary.Meeting) -> String {
        let heading = [meeting.date?.replacingOccurrences(of: "T", with: " "), meeting.title, meeting.duration,
                       meeting.folder.isEmpty ? nil : meeting.folder].compactMap { $0 }
        var details = [meeting.id.uuidString]
        if !meeting.participants.isEmpty { details.append(meeting.participants.joined(separator: ", ")) }
        return heading.joined(separator: " · ") + "\n    " + details.joined(separator: " · ")
    }

    /// The options after the command, checked against what the command takes.
    struct Options {
        struct Failure: Error { let message: String }

        var notesFolder: String?
        var json = false
        var from: String?
        var to: String?
        var query: String?
        var limit: Int?
        var includeTranscript = true
        var words: [String] = []

        init(_ arguments: [String], command: String) throws {
            let valued: Set<String> = switch command {
            case "list": ["--notes-folder", "--from", "--to", "--query", "--limit"]
            case "search": ["--notes-folder", "--limit"]
            default: ["--notes-folder"]
            }
            let flags: Set<String> = switch command {
            case "list", "search": ["--json"]
            case "get": ["--json", "--no-transcript"]
            default: []
            }
            var index = arguments.startIndex
            while index < arguments.endIndex {
                let argument = arguments[index]
                index += 1
                if flags.contains(argument) {
                    if argument == "--json" { json = true } else { includeTranscript = false }
                } else if valued.contains(argument) {
                    guard index < arguments.endIndex else { throw Failure(message: "\(argument) needs a value.") }
                    let value = arguments[index]
                    index += 1
                    switch argument {
                    case "--notes-folder": notesFolder = (value as NSString).expandingTildeInPath
                    case "--from", "--to":
                        guard value.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else {
                            throw Failure(message: "\(argument) takes a date as YYYY-MM-DD.")
                        }
                        if argument == "--from" { from = value } else { to = value }
                    case "--query": query = value
                    default:
                        guard let number = Int(value), number > 0 else { throw Failure(message: "--limit takes a number.") }
                        limit = number
                    }
                } else if argument.hasPrefix("-") {
                    throw Failure(message: "unknown option \(argument).")
                } else {
                    words.append(argument)
                }
            }
            switch command {
            case "search" where words.isEmpty: throw Failure(message: "say what to look for.")
            case "get" where words.count != 1: throw Failure(message: "give one meeting id.")
            case "list" where !words.isEmpty, "mcp" where !words.isEmpty: throw Failure(message: "unexpected \(words[0]).")
            default: break
            }
        }
    }
}
