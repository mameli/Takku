import Foundation

/// `takku import` and `takku regenerate`: checked here, then asked of the running app through the
/// requests folder, then followed through the Meeting's `processing.json` (ADR 0015).
extension MeetingCommand {
    /// Seconds between two looks at the requests folder or at `processing.json`.
    static let pollInterval: TimeInterval = 0.25
    /// The app must take a request (remove it from the folder) within this long of being opened.
    static let takeTimeout: TimeInterval = 30
    /// While waiting, the app may be missing this long before the command gives up: a relaunch.
    static let missingAppTimeout: TimeInterval = 10

    /// One request and what the command calls it in its messages: the file, or the meeting id.
    struct Sent {
        let request: AppRequest
        let label: String
    }

    func runThroughApp(_ command: String, options: Options, library: MeetingLibrary?, streams: Streams) -> Int32 {
        guard let state, let requests, let app else {
            streams.error("takku \(command): not available here.")
            return 1
        }
        guard let library else {
            streams.error("takku \(command): no notes folder is chosen in Takku: choose one in Settings → Notes.")
            return 1
        }
        let template: String?
        if let name = options.template {
            guard let found = state.template(named: name) else {
                streams.error("takku \(command): no Template named \"\(name)\": see takku templates.")
                return 1
            }
            template = found
        } else {
            template = nil
        }
        var profile: AppRequest.ProfileChoice?
        if let text = options.profile {
            switch state.profileChoice(text) {
            case .success(let choice): profile = choice
            case .failure(let failure):
                streams.error("takku \(command): \(failure.message)")
                return 1
            }
        }

        let sent: [Sent]
        if command == "import" {
            var files: [URL] = []
            for word in options.words {
                let url = URL(filePath: (word as NSString).expandingTildeInPath, relativeTo: workingDirectory).standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
                      !isDirectory.boolValue
                else {
                    streams.error("takku import: no file at \(url.path(percentEncoded: false)).")
                    return 1
                }
                files.append(url)
            }
            sent = files.map { file in
                Sent(
                    request: AppRequest(
                        kind: .importAudio, meetingID: UUID(), file: file.path(percentEncoded: false), template: template,
                        profile: profile, title: options.title, folder: options.folder
                    ),
                    label: file.lastPathComponent
                )
            }
        } else {
            guard let id = UUID(uuidString: options.words[0]) else {
                streams.error("takku regenerate: \(options.words[0]) is not a meeting id: use one from takku list.")
                return 1
            }
            guard let record = state.record(id) else {
                streams.error("takku regenerate: no meeting with id \(id.uuidString) in Takku's recordings.")
                return 1
            }
            guard !record.status.isPending else {
                streams.error("takku regenerate: the meeting is \(TakkuState.statusName(record.status)): wait for it to end (takku status \(id.uuidString)).")
                return 1
            }
            sent = [Sent(
                request: AppRequest(kind: .regenerate, meetingID: id, template: template, profile: profile),
                label: TakkuState.title(record)
            )]
        }
        return send(sent, command: command, options: options, state: state, library: library, requests: requests, app: app, streams: streams)
    }

    private func send(
        _ sent: [Sent], command: String, options: Options, state: TakkuState, library: MeetingLibrary,
        requests: AppRequestFolder, app: AppLink, streams: Streams
    ) -> Int32 {
        do {
            for item in sent { try requests.send(item.request) }
        } catch {
            sent.forEach { requests.withdraw($0.request.id) }
            streams.error("takku \(command): the request for Takku was not written: \(error.localizedDescription)")
            return 1
        }
        do {
            try app.open()
        } catch {
            sent.forEach { requests.withdraw($0.request.id) }
            streams.error("takku \(command): Takku did not open: \(error.localizedDescription)")
            return 1
        }

        // Takku takes every request as soon as it reads the folder, and answers them in order.
        var waited: TimeInterval = 0
        while sent.contains(where: { requests.isWaiting($0.request.id) }) {
            guard waited < Self.takeTimeout else {
                sent.forEach { requests.withdraw($0.request.id) }
                streams.error("takku \(command): Takku did not take the request. If you just updated it, quit Takku and open it again.")
                return 1
            }
            app.pause(Self.pollInterval)
            waited += Self.pollInterval
        }
        var accepted: [Sent] = []
        var failed = false
        for item in sent {
            switch waitForAnswer(item.request.id, requests: requests, app: app) {
            case .some(let answer):
                if let reason = answer.error {
                    streams.error("\(item.label): \(reason)")
                    failed = true
                } else {
                    accepted.append(item)
                }
            case nil:
                streams.error("takku \(command): Takku quit before taking in \(item.label).")
                return 1
            }
        }

        guard options.wait else {
            let ids = accepted.map(\.request.meetingID.uuidString)
            if options.json {
                let objects = accepted.map { ["id": $0.request.meetingID.uuidString, "label": $0.label] }
                let value: Any = command == "import" ? objects : (objects.first ?? [:])
                streams.output(MCPServer.json(value))
            } else if !ids.isEmpty {
                streams.output(ids.joined(separator: "\n"))
            }
            return failed ? 1 : 0
        }

        var objects: [[String: Any]] = []
        for item in accepted {
            guard let record = waitForEnd(item, state: state, app: app, streams: streams) else {
                streams.error("takku \(command): Takku quit while processing \(item.label); it goes on at the next launch: takku status \(item.request.meetingID.uuidString).")
                return 1
            }
            var reason: String?
            if case .failed(let why) = record.status {
                reason = why
                failed = true
                streams.error("\(item.label): \(why)")
            }
            // A folder new to this command (`--folder`, or the Template's `folder:`) was not read yet.
            let meeting = library.meeting(id: item.request.meetingID) ?? record.noteFolder.flatMap {
                MeetingLibrary(notesFolder: library.notesFolder, otherFolders: [$0]).meeting(id: item.request.meetingID)
            }
            if options.json {
                var object = meeting?.fullFields(includeTranscript: true) ?? ["id": item.request.meetingID.uuidString]
                object["status"] = TakkuState.statusName(record.status)
                object["error"] = reason ?? NSNull()
                objects.append(object)
            } else if let path = meeting?.note.path(percentEncoded: false) ?? record.noteURL?.path(percentEncoded: false) {
                streams.output(path)
            }
        }
        if options.json {
            let value: Any = command == "import" ? objects : (objects.first ?? [:])
            streams.output(MCPServer.json(value))
        }
        return failed ? 1 : 0
    }

    /// The app's answer; `nil` if it stopped running before giving one. A long file takes a while
    /// to convert, so there is no limit while the app runs.
    private func waitForAnswer(_ id: UUID, requests: AppRequestFolder, app: AppLink) -> AppRequestAnswer? {
        var missing: TimeInterval = 0
        while true {
            if let answer = requests.takeAnswer(to: id) { return answer }
            missing = app.isRunning() ? 0 : missing + Self.pollInterval
            if missing >= Self.missingAppTimeout { return nil }
            app.pause(Self.pollInterval)
        }
    }

    /// The Meeting's state once Processing ends, writing each change of state to stderr; `nil` if
    /// the app stopped running meanwhile.
    private func waitForEnd(_ item: Sent, state: TakkuState, app: AppLink, streams: Streams) -> ProcessingRecord? {
        var missing: TimeInterval = 0
        var shown: String?
        while true {
            if let record = state.record(item.request.meetingID) {
                let name = TakkuState.statusName(record.status)
                if name != shown {
                    streams.error("\(item.label): \(name)")
                    shown = name
                }
                if !record.status.isPending { return record }
            }
            missing = app.isRunning() ? 0 : missing + Self.pollInterval
            if missing >= Self.missingAppTimeout { return nil }
            app.pause(Self.pollInterval)
        }
    }
}

extension AppRequestFolder {
    /// The request is still in the folder: the app has not taken it.
    func isWaiting(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: requestURL(id).path(percentEncoded: false))
    }
}
