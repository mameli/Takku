import Foundation
import Testing
@testable import TakkuCore

@Suite("The meetings read from a terminal with takku list, search and get")
struct MeetingCommandTests {
    let fixture = MCPServerTests()

    /// Runs `takku <arguments>` on the fixture's notes folder.
    func run(_ arguments: [String], notesFolder: String? = nil) throws -> (status: Int32, output: String, error: String) {
        let folder = try notesFolder ?? fixture.notesFolder().path(percentEncoded: false)
        var output = "", error = ""
        let status = MeetingCommand(arguments: arguments, notesFolder: folder, version: "1.16.0").run(
            readLine: { nil }, output: { output += $0 }, error: { error += $0 }
        )
        return (status, output, error)
    }

    @Test("list prints a line per meeting, newest first, with its id; filters like the MCP tool")
    func list() throws {
        let all = try run(["list"])
        let withGiulia = try run(["list", "--query", "GIULIA", "--from", "2026-10-01", "--to", "2026-10-31"])

        #expect(all.status == 0)
        #expect(all.output.hasPrefix("2026-11-01 16:58 · Call di prova\n    \(fixture.callID.uuidString)"))
        #expect(all.output.contains("2026-10-20 10:00 · Retrospettiva sprint 12 · 45m · Archive/Retrospettive\n    \(fixture.retroID.uuidString) · Mario Rossi, Giulia Bianchi"))
        #expect(withGiulia.output.contains("Retrospettiva") && !withGiulia.output.contains("Call di prova"))
        #expect(try run(["list", "--limit", "1"]).output.components(separatedBy: "\n\n").count == 1)
    }

    @Test("--json prints the same fields as the MCP tools")
    func json() throws {
        let list = try run(["list", "--json"]).output
        let meetings = try #require(try JSONSerialization.jsonObject(with: Data(list.utf8)) as? [[String: Any]])
        let get = try run(["get", fixture.retroID.uuidString, "--json", "--no-transcript"]).output
        let meeting = try #require(try JSONSerialization.jsonObject(with: Data(get.utf8)) as? [String: Any])

        #expect(meetings.compactMap { $0["id"] as? String } == [fixture.callID.uuidString, fixture.retroID.uuidString])
        #expect((meeting["note"] as? String)?.contains("Il rilascio è andato liscio") == true)
        #expect(meeting["transcript"] == nil)
    }

    @Test("search prints the meetings with their matching lines")
    func search() throws {
        let result = try run(["search", "rilascio", "regressione"])

        #expect(result.status == 0)
        #expect(result.output.hasPrefix("2026-10-20 10:00 · Retrospettiva sprint 12"))
        #expect(result.output.contains("    > **[00:09] Giulia Bianchi (Speaker 1):** Il rilascio è andato bene, nessuna regressione."))
    }

    @Test("get prints the note and the transcript, or only the note")
    func get() throws {
        let full = try run(["get", fixture.retroID.uuidString]).output
        let note = try run(["get", fixture.retroID.uuidString, "--no-transcript"]).output

        #expect(full.contains("Il rilascio è andato liscio") && full.contains("nessuna regressione"))
        #expect(!note.contains("nessuna regressione"))
    }

    @Test("wrong arguments print the usage with status 2; an unknown meeting is status 1")
    func errors() throws {
        for arguments in [["search"], ["get"], ["list", "extra"], ["list", "--from", "ieri"], ["list", "--limit"], ["get", "x", "--from", "2026-01-01"]] {
            let result = try run(arguments)
            #expect(result.status == 2, "\(arguments)")
            #expect(result.error.contains("Usage: takku"), "\(arguments)")
        }
        #expect(try run(["get", UUID().uuidString]).status == 1)
        #expect(try run(["get", "nope"]).status == 1)
        #expect(try run(["help"]).output.contains("Usage: takku"))
    }

    @Test("--notes-folder wins over Settings; with neither the command says so")
    func notesFolder() throws {
        let folder = try fixture.notesFolder().path(percentEncoded: false)
        var error = ""
        let status = MeetingCommand(arguments: ["list"], notesFolder: nil, version: "1.16.0")
            .run(readLine: { nil }, output: { _ in }, error: { error += $0 })

        #expect(try run(["list", "--notes-folder", folder], notesFolder: "/nonexistent").output.contains("Call di prova"))
        #expect(status == 1 && error.contains("--notes-folder"))
    }

    @Test("mcp answers JSON-RPC on the same notes folder")
    func mcp() throws {
        var lines = [#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#]
        var output = ""
        let status = MeetingCommand(arguments: ["mcp"], notesFolder: nil, version: "1.16.0").run(
            readLine: { lines.isEmpty ? nil : lines.removeFirst() }, output: { output += $0 }, error: { _ in }
        )

        #expect(status == 0)
        #expect(output.contains("search_meetings"))
    }
}
