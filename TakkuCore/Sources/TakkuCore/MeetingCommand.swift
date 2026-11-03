import Foundation

/// `takku <command>`: the Meetings of the notes folder from a terminal or a script, without the
/// menu. `list`, `search`, `get`, `templates`, `profiles` and `status` only read; `mcp` serves the
/// same over MCP (`MCPServer`); `import` and `regenerate` ask the running app (ADR 0015, in
/// `MeetingCommand+App.swift`). Readable text, or with `--json` the same JSON the MCP tools answer with.
public struct MeetingCommand: Sendable {
    /// The first arguments that make the app run as a command instead of starting.
    public static let names: Set<String> = [
        "list", "search", "get", "templates", "profiles", "status", "import", "regenerate", "mcp", "help", "--help", "-h",
    ]

    static let usage = """
        Usage: takku <command> [options]

          list [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--query TEXT] [--limit N]
                              meetings, newest first; --query matches title, folder,
                              participants and speakers
          search WORDS [--limit N]
                              meetings whose note or transcript contains every word
          get ID [--no-transcript]
                              a meeting's note and transcript
          templates           the Summary Templates, the default marked
          profiles            the Summary Profiles, the active one marked
          status [ID]         meetings being recorded or processed, or one meeting
          import FILE... [--template NAME] [--profile NAME|transcript] [--title TEXT]
                 [--folder FOLDER] [--no-wait]
                              audio or video files made meetings by Takku, which opens
                              if needed; waits for each note and prints its path.
                              --folder is inside Meetings/, e.g. YouTube
          regenerate ID [--template NAME] [--profile NAME|transcript] [--no-wait]
                              a new Summary from the meeting's current transcript;
                              by default with the meeting's own Template and Profile
          mcp                 serves the meetings to an AI assistant over MCP (stdio),
                              read only

        list, search, get and mcp take --notes-folder PATH (default: the one chosen in
        Takku's Settings); every command but mcp takes --json.
        """

    /// What `import` and `regenerate` need of the app: whether it is running, opening it, and
    /// waiting between two looks at the requests folder (no wait in tests).
    public struct AppLink: Sendable {
        public var isRunning: @Sendable () -> Bool
        public var open: @Sendable () throws -> Void
        public var pause: @Sendable (TimeInterval) -> Void

        public init(
            isRunning: @escaping @Sendable () -> Bool, open: @escaping @Sendable () throws -> Void,
            pause: @escaping @Sendable (TimeInterval) -> Void
        ) {
            self.isRunning = isRunning
            self.open = open
            self.pause = pause
        }
    }

    let arguments: [String]
    let notesFolder: String?
    let version: String
    let state: TakkuState?
    let requests: AppRequestFolder?
    let app: AppLink?
    /// Where relative file paths given to `import` start from.
    let workingDirectory: URL

    /// `arguments` without the program name; `notesFolder` is the one chosen in Settings. Without
    /// `state`, `requests` and `app` only the commands that read the notes folder work.
    public init(
        arguments: [String], notesFolder: String?, version: String, state: TakkuState? = nil,
        requests: AppRequestFolder? = nil, app: AppLink? = nil,
        workingDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    ) {
        self.arguments = arguments
        self.notesFolder = notesFolder
        self.version = version
        self.state = state
        self.requests = requests
        self.app = app
        self.workingDirectory = workingDirectory
    }

    /// Where the command writes: `output` is stdout, `error` stderr.
    struct Streams {
        let output: (String) -> Void
        let error: (String) -> Void
    }

    /// Runs the command and returns its exit status: 0 done, 1 failed, 2 wrong arguments.
    public func run(
        readLine: () -> String?, output: (String) -> Void, error: (String) -> Void
    ) -> Int32 {
        withoutActuallyEscaping(output) { output in
            withoutActuallyEscaping(error) { error in
                run(readLine: readLine, streams: Streams(output: output, error: error))
            }
        }
    }

    private func run(readLine: () -> String?, streams: Streams) -> Int32 {
        let output = streams.output, error = streams.error
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
            MCPServer(library: library, version: version, state: state).run(readLine: readLine, write: output)
            return 0
        }
        switch command {
        case "templates", "profiles", "status":
            guard let state else {
                error("takku \(command): not available here.")
                return 1
            }
            return runState(command, options: options, state: state, streams: streams)
        case "import", "regenerate":
            return runThroughApp(command, options: options, library: library, streams: streams)
        default:
            break
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
            output(options.json
                ? MCPServer.json(meeting.fullFields(includeTranscript: options.includeTranscript))
                : meeting.text(includeTranscript: options.includeTranscript))
        }
        return 0
    }

    /// `templates`, `profiles` and `status`: what the app knows, read without it.
    private func runState(_ command: String, options: Options, state: TakkuState, streams: Streams) -> Int32 {
        switch command {
        case "templates":
            streams.output(options.json
                ? MCPServer.json(state.templateFields)
                : state.templates.map { $0 == state.defaultTemplate ? "\($0) (default)" : $0 }.joined(separator: "\n"))
        case "profiles":
            if options.json {
                streams.output(MCPServer.json(state.profileFields))
            } else {
                let lines = state.profiles.map { profile in
                    let place = profile.runsOnThisMac ? "on this Mac" : "remote"
                    let active = profile.id == state.activeProfileID ? " (active)" : ""
                    return "\(profile.displayName) · \(profile.model) · \(place)\(active)\n    \(profile.id.uuidString)"
                }
                let transcript = "Transcript · no Summary" + (state.activeProfileID == nil ? " (active)" : "")
                streams.output((lines + [transcript]).joined(separator: "\n\n"))
            }
        default:
            if let word = options.words.first {
                guard let id = UUID(uuidString: word) else {
                    streams.error("takku status: \(word) is not a meeting id: use one from takku list or takku import.")
                    return 1
                }
                guard let record = state.record(id) else {
                    streams.error("takku status: no meeting with id \(word) in Takku's recordings.")
                    return 1
                }
                streams.output(options.json ? MCPServer.json(state.statusFields(record)) : TakkuState.line(record))
            } else {
                let pending = state.pendingRecords()
                if options.json {
                    streams.output(MCPServer.json(pending.map(state.statusFields)))
                } else {
                    streams.output(pending.isEmpty ? "Nothing being recorded or processed." : pending.map(TakkuState.line).joined(separator: "\n\n"))
                }
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
        var template: String?
        var profile: String?
        var title: String?
        var folder: String?
        var wait = true
        var words: [String] = []

        init(_ arguments: [String], command: String) throws {
            let valued: Set<String> = switch command {
            case "list": ["--notes-folder", "--from", "--to", "--query", "--limit"]
            case "search": ["--notes-folder", "--limit"]
            case "get", "mcp": ["--notes-folder"]
            case "import": ["--template", "--profile", "--title", "--folder"]
            case "regenerate": ["--template", "--profile"]
            default: []
            }
            let flags: Set<String> = switch command {
            case "list", "search", "templates", "profiles", "status": ["--json"]
            case "get": ["--json", "--no-transcript"]
            case "import", "regenerate": ["--json", "--no-wait"]
            default: []
            }
            var index = arguments.startIndex
            while index < arguments.endIndex {
                let argument = arguments[index]
                index += 1
                if flags.contains(argument) {
                    switch argument {
                    case "--json": json = true
                    case "--no-wait": wait = false
                    default: includeTranscript = false
                    }
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
                    case "--template": template = value
                    case "--profile": profile = value
                    case "--title":
                        guard let name = VaultNaming.fileName(value) else {
                            throw Failure(message: "--title has nothing a note name can keep.")
                        }
                        title = name
                    case "--folder":
                        switch VaultNaming.noteFolder(value) {
                        case .success(let checked): folder = checked
                        case .failure(let invalid): throw Failure(message: "--folder: \(invalid.message)")
                        }
                    default:
                        guard let number = Int(value), number > 0 else { throw Failure(message: "--limit takes a number.") }
                        limit = number
                    }
                } else if argument.hasPrefix("-") && argument != "-" {
                    throw Failure(message: "unknown option \(argument).")
                } else {
                    words.append(argument)
                }
            }
            switch command {
            case "search" where words.isEmpty: throw Failure(message: "say what to look for.")
            case "get" where words.count != 1, "regenerate" where words.count != 1: throw Failure(message: "give one meeting id.")
            case "import" where words.isEmpty: throw Failure(message: "give the audio or video files to import.")
            case "status" where words.count > 1: throw Failure(message: "give at most one meeting id.")
            case "list" where !words.isEmpty, "mcp" where !words.isEmpty, "templates" where !words.isEmpty,
                 "profiles" where !words.isEmpty:
                throw Failure(message: "unexpected \(words[0]).")
            default: break
            }
        }
    }
}
