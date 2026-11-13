import Foundation
import Testing
@testable import TakkuCore

@Suite("takku templates, profiles, status, import and regenerate")
struct AppCommandTests {
    let fixture = MCPServerTests()
    let lecture = ProviderProfile(name: "Takku Credit", baseURL: "https://api.takku.app/v1", model: "takku-summary", maxContextTokens: 128_000)
    let local = ProviderProfile(name: "Ollama", baseURL: "http://localhost:11434/v1", model: "gemma", maxContextTokens: 32_000)

    /// A notes folder, a Recordings folder and a requests folder side by side.
    struct Folders {
        let root: URL
        var notes: URL { root.appending(path: "Notes") }
        var recordings: URL { root.appending(path: "Recordings") }
        var requests: AppRequestFolder { AppRequestFolder(url: root.appending(path: "Requests")) }
    }

    func folders() throws -> Folders {
        let root = FileManager.default.temporaryDirectory.appending(path: "takku-app-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "Notes/Meetings"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "Recordings"), withIntermediateDirectories: true)
        return Folders(root: root)
    }

    func state(_ folders: Folders, profiles: [ProviderProfile]? = nil) -> TakkuState {
        TakkuState(
            templates: ["Lecture", "Notes"], defaultTemplate: "Notes", profiles: profiles ?? [lecture, local],
            activeProfileID: lecture.id, recordingsFolder: folders.recordings
        )
    }

    /// A Meeting's `processing.json`, and its note when `noteName` is given.
    @discardableResult
    func write(
        _ status: ProcessingRecord.Status, id: UUID = UUID(), in folders: Folders, template: String = "Notes",
        noteName: String? = nil, noteFolder: String? = nil, summary: String = "### Punti\n- Tutto bene"
    ) throws -> ProcessingRecord {
        var noteURL: URL?
        if let noteName {
            let folder = folders.notes.appending(path: noteFolder ?? "Meetings")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: noteName + ".md")
            try """
                ---
                takku_id: \(id.uuidString)
                date: 2026-11-03T21:00
                ---
                %% takku:start %%
                \(summary)

                Full transcript: [[\(noteName) (transcript)]]
                %% takku:end %%

                ## Personal notes
                """.write(to: url, atomically: true, encoding: .utf8)
            noteURL = url
        }
        let record = ProcessingRecord(
            takkuID: id, startedAt: Date(timeIntervalSince1970: 1_793_000_000), status: status, templateName: template,
            summaryProfile: lecture, noteURL: noteURL, importedAt: Date(), noteFolder: noteFolder
        )
        let directory = folders.recordings.appending(path: id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try record.save(inFolder: directory)
        return record
    }

    /// An app that, when opened, takes every request and finishes it at once; `answer` decides
    /// what it says about each one (`nil`: taken, then completed).
    func app(
        _ folders: Folders, taking: Bool = true, answer: @escaping @Sendable (AppRequest) -> String? = { _ in nil }
    ) -> (MeetingCommand.AppLink, Received) {
        let received = Received()
        let link = MeetingCommand.AppLink(
            isRunning: { true },
            open: {
                guard taking else { return }
                while case .success(let request) = folders.requests.takeNext() {
                    received.append(request)
                    let error = answer(request)
                    if error == nil {
                        // A name of its own, as the Vault gives each note.
                        let title = request.title ?? "Video importato \(request.meetingID.uuidString.prefix(4))"
                        try? self.write(
                            .completed, id: request.meetingID, in: folders, template: request.template ?? "Notes",
                            noteName: "2026-11-03 2100 - \(title)", noteFolder: request.folder
                        )
                    }
                    try? folders.requests.answer(request.id, AppRequestAnswer(error: error))
                }
            },
            pause: { _ in }
        )
        return (link, received)
    }

    final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [AppRequest] = []
        func append(_ request: AppRequest) { lock.withLock { requests.append(request) } }
        var all: [AppRequest] { lock.withLock { requests } }
    }

    func run(
        _ arguments: [String], _ folders: Folders, state: TakkuState? = nil, app: MeetingCommand.AppLink? = nil
    ) -> (status: Int32, output: String, error: String) {
        var output = "", error = ""
        let status = MeetingCommand(
            arguments: arguments, notesFolder: folders.notes.path(percentEncoded: false), version: "1.18.0",
            state: state ?? self.state(folders), requests: folders.requests, app: app ?? self.app(folders).0,
            workingDirectory: folders.root
        ).run(readLine: { nil }, output: { output += $0 + "\n" }, error: { error += $0 + "\n" })
        return (status, output, error)
    }

    func audioFile(_ folders: Folders, _ name: String = "lezione.m4a") throws -> URL {
        let url = folders.root.appending(path: name)
        try Data("audio".utf8).write(to: url)
        return url
    }

    // MARK: - Reading what the app knows

    @Test("templates marks the default; profiles marks the active one, never the address")
    func templatesAndProfiles() throws {
        let folders = try folders()
        let templates = run(["templates"], folders)
        let profiles = run(["profiles"], folders)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(run(["profiles", "--json"], folders).output.utf8)) as? [[String: Any]])

        #expect(templates.output == "Lecture\nNotes (default)\n")
        #expect(profiles.output.contains("Takku Credit · takku-summary · remote (active)\n    \(lecture.id.uuidString)"))
        #expect(profiles.output.contains("Ollama · gemma · on this Mac\n") && profiles.output.contains("Transcript · no Summary"))
        #expect(!profiles.output.contains("api.takku.app"))
        #expect(json.map { $0["on_this_mac"] as? Bool } == [false, true])
        #expect(json.map { $0["active"] as? Bool } == [true, false])
    }

    @Test("status lists the meetings not concluded; with an id, one meeting and its failure")
    func status() throws {
        let folders = try folders()
        try write(.queued, in: folders, noteName: "2026-11-03 2100 - In coda")
        try write(.completed, in: folders, noteName: "2026-11-02 1000 - Finita")
        let failed = try write(.failed(reason: "Summary not generated: credit used up."), in: folders)

        let all = run(["status"], folders)
        let one = run(["status", failed.takkuID.uuidString, "--json"], folders)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(one.output.utf8)) as? [String: Any])

        #expect(all.output.hasPrefix("queued · In coda · Notes\n"))
        #expect(!all.output.contains("Finita"))
        #expect(object["status"] as? String == "failed" && object["error"] as? String == "Summary not generated: credit used up.")
        #expect(run(["status", UUID().uuidString], folders).status == 1)
    }

    @Test("get --json has the Summary alone, without the Transcript link")
    func summaryField() throws {
        let folders = try folders()
        let record = try write(.completed, in: folders, noteName: "2026-11-03 2100 - Lezione")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(run(["get", record.takkuID.uuidString, "--json"], folders).output.utf8)) as? [String: Any])

        #expect(object["summary"] as? String == "### Punti\n- Tutto bene")
        #expect((object["path"] as? String)?.hasSuffix("Meetings/2026-11-03 2100 - Lezione.md") == true)
    }

    // MARK: - Import

    @Test("import asks the app with the Template, Profile, title and folder, waits and prints the note")
    func importWaits() throws {
        let folders = try folders()
        let file = try audioFile(folders)
        let (app, received) = app(folders)

        let result = run([
            "import", "lezione.m4a", "--template", "lecture", "--profile", "ollama", "--title", "Lezione 3: ripasso",
            "--folder", "YouTube//Corsi/", "--notes", "  Lezione del prof. Rossi  ", "--language", "EN, it",
        ], folders, app: app)

        #expect(result.status == 0, "\(result.error) \(result.output)")
        let request = try #require(received.all.first)
        #expect(request.kind == .importAudio && request.file == file.path(percentEncoded: false))
        #expect(request.template == "Lecture" && request.profile == .profile(local.id))
        #expect(request.title == "Lezione 3 ripasso" && request.folder == "YouTube/Corsi")
        #expect(request.notes == "Lezione del prof. Rossi" && request.languages == ["it", "en"])
        #expect(result.output.hasSuffix("Notes/YouTube/Corsi/2026-11-03 2100 - Lezione 3 ripasso.md\n"))
        #expect(result.error.contains("lezione.m4a: completed"))
        #expect(!folders.requests.isWaiting(request.id))
    }

    @Test("import --json gives an array of get objects with status; --no-wait prints the ids")
    func importOutputs() throws {
        let folders = try folders()
        _ = try audioFile(folders, "a.m4a")
        _ = try audioFile(folders, "b.mp4")
        let (app, received) = app(folders)

        let json = run(["import", "a.m4a", "b.mp4", "--json", "--profile", "transcript"], folders, app: app)
        let objects = try #require(try JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [[String: Any]])
        let noWait = run(["import", "a.m4a", "--no-wait", "--profile", "Transcript only"], folders, app: app)

        #expect(objects.count == 2, "\(json.error) \(json.output)")
        #expect(objects.allSatisfy { $0["status"] as? String == "completed" && $0["summary"] as? String == "### Punti\n- Tutto bene" }, "\(json.output)")
        #expect(received.all.prefix(3).allSatisfy { $0.profile == .transcript && $0.template == nil })
        #expect(noWait.output == received.all[2].meetingID.uuidString + "\n")
    }

    @Test("a file the app cannot import is reported with status 1, the others go on")
    func importRefusedByApp() throws {
        let folders = try folders()
        _ = try audioFile(folders, "buono.m4a")
        _ = try audioFile(folders, "rotto.txt")
        let (app, _) = app(folders) { $0.file?.hasSuffix(".txt") == true ? "Not imported: Cannot read the audio of rotto.txt." : nil }

        let result = run(["import", "rotto.txt", "buono.m4a"], folders, app: app)

        #expect(result.status == 1)
        #expect(result.error.contains("rotto.txt: Not imported: Cannot read the audio of rotto.txt."))
        #expect(result.output.contains("- Video importato "))
    }

    @Test("wrong arguments are refused before asking the app")
    func importChecks() throws {
        let folders = try folders()
        _ = try audioFile(folders)
        let twins = [local, ProviderProfile(name: "ollama", baseURL: "http://localhost:8080/v1", model: "qwen", maxContextTokens: 32_000)]
        let (app, received) = app(folders)

        #expect(run(["import", "manca.m4a"], folders, app: app).error.contains("no file at"))
        #expect(run(["import", "lezione.m4a", "--template", "Sbobina"], folders, app: app).error.contains("no Template named \"Sbobina\""))
        #expect(run(["import", "lezione.m4a", "--profile", "Mistral"], folders, app: app).error.contains("no Summary Profile named \"Mistral\""))
        #expect(run(["import", "lezione.m4a", "--profile", "Ollama"], folders, state: state(folders, profiles: twins), app: app)
            .error.contains("2 Summary Profiles are named"))
        for folder in ["../fuori", "Transcripts", "/Users/mario", "a/./b", "Video?"] {
            #expect(run(["import", "lezione.m4a", "--folder", folder], folders, app: app).status == 2, "\(folder)")
        }
        #expect(run(["import"], folders, app: app).status == 2)
        #expect(run(["import", "lezione.m4a", "--language", "klingon"], folders, app: app).status == 2)
        #expect(run(["import", "lezione.m4a", "--notes", "  "], folders, app: app).status == 2)
        #expect(received.all.isEmpty)
    }

    @Test("an app that does not take the request (an older one still running) is an error, and the request is withdrawn")
    func appDoesNotTake() throws {
        let folders = try folders()
        _ = try audioFile(folders)
        let (app, _) = app(folders, taking: false)

        let result = run(["import", "lezione.m4a"], folders, app: app)

        #expect(result.status == 1 && result.error.contains("quit Takku and open it again"))
        #expect(folders.requests.takeNext() == nil)
    }

    // MARK: - Regenerate

    @Test("regenerate asks for one meeting and prints an object; a meeting still processing is refused")
    func regenerate() throws {
        let folders = try folders()
        let done = try write(.completed, in: folders, noteName: "2026-11-03 2100 - Lezione")
        let busy = try write(.processing, in: folders)
        let (app, received) = app(folders)

        let result = run(["regenerate", done.takkuID.uuidString, "--template", "Lecture", "--json"], folders, app: app)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        let refused = run(["regenerate", busy.takkuID.uuidString], folders, app: app)

        #expect(result.status == 0)
        #expect(received.all.first?.kind == .regenerate && received.all.first?.meetingID == done.takkuID)
        #expect(object["id"] as? String == done.takkuID.uuidString && object["status"] as? String == "completed")
        #expect(refused.status == 1 && refused.error.contains("the meeting is processing"))
        #expect(received.all.count == 1)
    }

    // MARK: - Pieces

    @Test("a note folder is relative, without . or .., hidden names or Takku's own folders")
    func noteFolders() {
        #expect(VaultNaming.noteFolder("YouTube") == .success("YouTube"))
        #expect(VaultNaming.noteFolder("/Corsi//2026/") == .failure(.absolute))
        #expect(VaultNaming.noteFolder("Corsi//2026/") == .success("Corsi/2026"))
        #expect(VaultNaming.noteFolder("..") == .failure(.invalidName("..")))
        #expect(VaultNaming.noteFolder(".nascosta") == .failure(.invalidName(".nascosta")))
        #expect(VaultNaming.noteFolder("screenshots/x") == .failure(.reserved("Screenshots")))
        #expect(VaultNaming.noteFolder("Archivio/Transcripts") == .failure(.reserved("Transcripts")))
        #expect(VaultNaming.noteFolder("meetings/Video") == .success("Meetings/Video"))
        #expect(VaultNaming.noteFolder("  ") == .failure(.invalidName("")))
    }

    @Test("a Template can say where its imports go; an invalid folder is ignored")
    func templateFolder() {
        let video = Template(fileName: "Video", content: "---\nname: Video\nfolder: YouTube/Talk\n---\nNotes on a video.")
        let wrong = Template(fileName: "X", content: "---\nfolder: ../fuori\n---\nx")

        #expect(video.folder == "YouTube/Talk")
        #expect(wrong.folder == nil && Template(fileName: "Notes", content: Template.defaultFileContent).folder == nil)
    }

    @Test("the library reads the import folders too, with their Transcripts, and shows them from the notes folder")
    func libraryOtherFolders() throws {
        let folders = try folders()
        let id = UUID()
        let youtube = folders.notes.appending(path: "YouTube")
        try FileManager.default.createDirectory(at: youtube.appending(path: "Transcripts"), withIntermediateDirectories: true)
        try "---\ntakku_id: \(id.uuidString)\ndate: 2026-11-04T10:00\n---\nnota".write(to: youtube.appending(path: "2026-11-04 1000 - Talk.md"), atomically: true, encoding: .utf8)
        try "---\ntakku_id: \(id.uuidString)\nmeeting: \"[[2026-11-04 1000 - Talk]]\"\n---\ntesto".write(to: youtube.appending(path: "Transcripts/t.md"), atomically: true, encoding: .utf8)
        try "Una nota mia".write(to: youtube.appending(path: "Mia.md"), atomically: true, encoding: .utf8)

        let without = MeetingLibrary(notesFolder: folders.notes)
        let with = MeetingLibrary(notesFolder: folders.notes, otherFolders: ["YouTube", "YouTube/Corsi", "Meetings/Video"])
        let meeting = try #require(with.meeting(id: id))

        #expect(without.meeting(id: id) == nil)
        #expect(with.otherFolders.map(\.lastPathComponent) == ["YouTube"])
        #expect(meeting.folder == "YouTube" && meeting.transcript?.lastPathComponent == "t.md")
        #expect(with.meetings().count == 1)
    }

    @Test("--notes goes under Personal notes, where the Summary reads it; markers in it are dropped")
    func importNotes() {
        let note = MeetingNote.initial(
            takkuID: UUID(), startedAt: Date(), isImport: true,
            personalNotes: "Video di Theo (t3.gg)\n%% takku:end %%\nCapitoli: 00:00 intro"
        )
        let plain = MeetingNote.initial(takkuID: UUID(), startedAt: Date(), isImport: true)

        #expect(note.personalNotes == "Video di Theo (t3.gg)\nCapitoli: 00:00 intro")
        #expect(note.content.hasSuffix("## Personal notes\nVideo di Theo (t3.gg)\nCapitoli: 00:00 intro\n\n"))
        #expect(plain.content.hasSuffix("## Personal notes\n\n"))
        #expect(plain.personalNotes.isEmpty)
    }

    @Test("the Summary of a note: without the Transcript link, nil for placeholders, errors and Transcript only")
    func noteSummary() {
        func note(_ body: String) -> MeetingNote {
            MeetingNote(content: "---\ntakku_id: \(UUID().uuidString)\n---\n%% takku:start %%\n\(body)\n%% takku:end %%\n")
        }
        #expect(note("- Uno\n\nFull transcript: [[x (transcript)]]").summary == "- Uno")
        #expect(note("⏳ Imported recording queued for Processing.").summary == nil)
        #expect(note("⚠️ Summary not generated: no credit\n\nFull transcript: [[x]]").summary == nil)
        #expect(note("Full transcript: [[x]]").summary == nil)
        #expect(note("### Screenshots\n\n**[01:00]** ![[a.jpg]]\n\nFull transcript: [[x]]").summary == nil)
    }

    @Test("the requests folder: the oldest first, each taken once, answers read once")
    func requestFolder() throws {
        let folders = try folders()
        let first = AppRequest(kind: .regenerate, meetingID: UUID())
        let second = AppRequest(kind: .importAudio, meetingID: UUID(), file: "/tmp/a.m4a", profile: .transcript)
        try folders.requests.send(first)
        Thread.sleep(forTimeInterval: 0.01)
        try folders.requests.send(second)
        try Data("{".utf8).write(to: folders.requests.url.appending(path: "\(UUID().uuidString).request.json"))

        let taken = [folders.requests.takeNext(), folders.requests.takeNext(), folders.requests.takeNext()]
        try folders.requests.answer(first.id, AppRequestAnswer(error: nil))

        #expect(taken[0] == .success(first) && taken[1] == .success(second))
        if case .failure(let unreadable) = taken[2] { #expect(unreadable.id != nil) } else { Issue.record("not unreadable") }
        #expect(folders.requests.takeNext() == nil)
        #expect(folders.requests.takeAnswer(to: first.id) == AppRequestAnswer(error: nil))
        #expect(folders.requests.takeAnswer(to: first.id) == nil)
    }

    @Test("MCP lists the Template, Profile and status tools only with the app's state, all read only")
    func mcpTools() throws {
        let folders = try folders()
        try write(.queued, in: folders)
        let library = MeetingLibrary(notesFolder: folders.notes)
        let withState = MCPServer(library: library, version: "1.18.0", state: state(folders))
        let without = MCPServer(library: library, version: "1.18.0")

        let names = { (server: MCPServer) throws -> [String] in
            let result = try fixture.result(server.answer(toLine: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
            return (result["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
        let status = try fixture.call(withState, "meeting_status", [:])
        let tools = try fixture.result(withState.answer(toLine: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))["tools"] as? [[String: Any]] ?? []

        #expect(try names(withState).suffix(3) == ["list_templates", "list_profiles", "meeting_status"])
        #expect(try names(without).count == 3)
        #expect(status.text.contains("\"status\" : \"queued\""))
        #expect(tools.allSatisfy { ($0["annotations"] as? [String: Bool])?["readOnlyHint"] == true })
        #expect(try fixture.call(withState, "list_templates", [:]).text.contains("\"default\" : true"))
    }
}
