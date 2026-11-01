import Foundation
import Testing
import TakkuCore

@Suite("The meetings served to agents over MCP")
struct MCPServerTests {
    let retroID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let callID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    /// A notes folder with two Meetings, one moved into a subfolder, and a stray file.
    func notesFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "takku-mcp-\(UUID().uuidString)")
        let meetings = root.appending(path: "Meetings")
        try FileManager.default.createDirectory(at: meetings.appending(path: "Archive/Retrospettive"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: meetings.appending(path: "Transcripts"), withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws {
            try text.write(to: meetings.appending(path: path), atomically: true, encoding: .utf8)
        }
        try write("Archive/Retrospettive/2026-10-20 1000 - Retrospettiva sprint 12.md", """
            ---
            takku_id: \(retroID.uuidString)
            date: 2026-10-20T10:00
            tags: [meeting]
            participants:
              - Mario Rossi
              - Giulia Bianchi
            duration: 45m
            transcript: "[[2026-10-20 1000 - Retrospettiva sprint 12 (transcript)]]"
            speakers:
              - Speaker 1 = Giulia Bianchi
            ---
            %% takku:start %%
            ### Cosa è andato bene
            - Il rilascio è andato liscio
            %% takku:end %%

            ## Personal notes
            Ricordarsi la demo
            """)
        try write("Transcripts/2026-10-20 1000 - Retrospettiva sprint 12 (transcript).md", """
            ---
            takku_id: \(retroID.uuidString)
            meeting: "[[2026-10-20 1000 - Retrospettiva sprint 12]]"
            ---
            **[00:01] Me:** Partiamo dal rilascio della settimana scorsa.

            **[00:09] Giulia Bianchi (Speaker 1):** Il rilascio è andato bene, nessuna regressione.
            """)
        try write("2026-11-01 1658 - Call di prova.md", """
            ---
            takku_id: \(callID.uuidString)
            date: 2026-11-01T16:58
            ---
            %% takku:start %%
            - La call di prova funziona, compresa l'eco
            %% takku:end %%
            """)
        try write("Idee sparse.md", "Niente frontmatter, non è una riunione.")
        return root
    }

    func server() throws -> MCPServer {
        MCPServer(library: MeetingLibrary(notesFolder: try notesFolder()), version: "1.14.0")
    }

    /// The `result` of a JSON-RPC answer.
    func result(_ answer: String?) throws -> [String: Any] {
        let answer = try #require(answer)
        let object = try JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any]
        return try #require(object?["result"] as? [String: Any])
    }

    func call(_ server: MCPServer, _ tool: String, _ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": tool, "arguments": arguments]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let result = try result(server.answer(toLine: line))
        let content = try #require((result["content"] as? [[String: Any]])?.first)
        return (try #require(content["text"] as? String), result["isError"] as? Bool ?? false)
    }

    @Test("initialize names the server and offers tools; a notification gets no answer")
    func initialize() throws {
        let server = try server()
        let result = try result(server.answer(toLine: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#))

        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "takku")
        #expect(server.answer(toLine: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test("tools/list offers the three tools")
    func toolsList() throws {
        let result = try result(try server().answer(toLine: #"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#))

        #expect((result["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["list_meetings", "search_meetings", "get_meeting"])
    }

    @Test("an unknown method is an error, a broken line a parse error")
    func errors() throws {
        let server = try server()
        #expect(server.answer(toLine: #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#)?.contains("-32601") == true)
        #expect(server.answer(toLine: "not json")?.contains("-32700") == true)
    }

    @Test("meetings are listed newest first, found in subfolders, with their metadata")
    func list() throws {
        let library = MeetingLibrary(notesFolder: try notesFolder())
        let meetings = library.meetings()

        #expect(meetings.map(\.title) == ["Call di prova", "Retrospettiva sprint 12"])
        #expect(meetings[1].folder == "Archive/Retrospettive")
        #expect(meetings[1].participants == ["Mario Rossi", "Giulia Bianchi"])
        #expect(meetings[1].speakers == ["Speaker 1 = Giulia Bianchi"])
        #expect(meetings[1].transcript?.lastPathComponent == "2026-10-20 1000 - Retrospettiva sprint 12 (transcript).md")
        #expect(meetings[0].transcript == nil)
    }

    @Test("list_meetings filters by date and by participant")
    func listFiltered() throws {
        let server = try server()
        let recent = try call(server, "list_meetings", ["from": "2026-10-25"]).text
        let withGiulia = try call(server, "list_meetings", ["query": "giulia"]).text

        #expect(recent.contains("Call di prova") && !recent.contains("Retrospettiva"))
        #expect(withGiulia.contains("Retrospettiva") && !withGiulia.contains("Call di prova"))
    }

    @Test("search finds every word in the summary or the transcript, accents ignored, with the lines")
    func search() throws {
        let library = MeetingLibrary(notesFolder: try notesFolder())
        let matches = library.search("RILASCIO regressione")

        #expect(matches.map(\.meeting.id) == [retroID])
        #expect(matches[0].lines.contains("**[00:09] Giulia Bianchi (Speaker 1):** Il rilascio è andato bene, nessuna regressione."))
        #expect(library.search("eco").map(\.meeting.id) == [callID])
        #expect(library.search("rilascio inesistente").isEmpty)
    }

    @Test("get_meeting reads the note and the transcript; a wrong id is an error")
    func get() throws {
        let server = try server()
        let full = try call(server, "get_meeting", ["id": retroID.uuidString])
        let noTranscript = try call(server, "get_meeting", ["id": retroID.uuidString, "include_transcript": false])

        #expect(!full.isError)
        #expect(full.text.contains("Il rilascio è andato liscio") && full.text.contains("nessuna regressione"))
        #expect(!noTranscript.text.contains("nessuna regressione"))
        #expect(try call(server, "get_meeting", ["id": "nope"]).isError)
        #expect(try call(server, "get_meeting", ["id": UUID().uuidString]).isError)
    }

    @Test("without a notes folder every tool says so")
    func noFolder() throws {
        let result = try call(MCPServer(library: nil, version: "1.14.0"), "list_meetings", [:])

        #expect(result.isError)
        #expect(result.text.contains("Settings"))
    }
}
