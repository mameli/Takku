import Foundation
import os

extension AgentCLI {
    /// Why an agent's run could not give a Summary. Looked up in the app's string catalog
    /// (Bundle.main), so the app can translate them.
    public enum Failure: LocalizedError, Equatable {
        case notInstalled(AgentCLI), notSignedIn(AgentCLI), timedOut(AgentCLI), emptyReply(AgentCLI)
        /// The agent has no model of its own (OpenCode, Pi) and the Profile names none.
        case noModel(AgentCLI)
        /// The model would reach the CLI as one of its options.
        case invalidModel(AgentCLI, String)
        /// The agent's own message, as it wrote it.
        case failed(AgentCLI, String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled(let cli):
                String(localized: "\(cli.name) is not installed: install it with \(cli.installCommand) in Terminal, then sign in with \(cli.signInCommand).")
            case .notSignedIn(let cli):
                String(localized: "\(cli.name) is not signed in: run \(cli.signInCommand) in Terminal, then try again.")
            case .timedOut(let cli):
                String(localized: "\(cli.name) did not answer within 15 minutes.")
            case .emptyReply(let cli):
                String(localized: "\(cli.name) finished without writing anything.")
            case .noModel(let cli):
                String(localized: "\(cli.name) needs a model: choose one in its Profile in Settings → Summary.")
            case .invalidModel(let cli, let model):
                String(localized: "\"\(model)\" is not a model name for \(cli.name): choose one in its Profile in Settings → Summary.")
            case .failed(let cli, let reason):
                String(localized: "\(cli.name): \(reason)")
            }
        }
    }

    /// Runs the user's CLI: one run per Chat Completions request, the sign-in check and the list
    /// of models. Cancelling the task, as *Stop processing* does, ends the run.
    public struct Runner: Sendable {
        let cli: AgentCLI
        private let locate: @Sendable () -> URL?
        private let environment: [String: String]
        private let timeout: Duration
        private let log: @Sendable (String) -> Void

        /// `locate` finds the executable before each run (the user may install it in the
        /// meantime); `environment` is Takku's, which the run gets without the API keys.
        public init(
            _ cli: AgentCLI, locate: (@Sendable () -> URL?)? = nil,
            environment: [String: String] = ProcessInfo.processInfo.environment, timeout: Duration = .seconds(900),
            log: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.cli = cli
            self.locate = locate ?? { cli.locate() }
            self.environment = environment
            self.timeout = timeout
            self.log = log
        }

        /// A client for the Profile: each request is one run of the CLI.
        public func client(for profile: ProviderProfile) -> ChatClient {
            let model = profile.model.trimmingCharacters(in: .whitespaces)
            let reasoning = profile.reasoning
            return ChatClient(baseURL: URL(string: cli.baseURL)!, apiKey: nil, model: model.isEmpty ? cli.name : model) { request in
                try await complete(request, model: model, reasoning: reasoning)
            }
        }

        /// Why the CLI cannot be used now, `nil` when it can as far as can be told without a run.
        public func unavailability() async -> Failure? {
            guard let executable = locate() else { return .notInstalled(cli) }
            guard let check = cli.signInCheckArguments,
                  let result = try? await runAside(executable, check, timeout: .seconds(30)), result.ending == .exited
            else { return nil }
            return cli.isSignedIn(status: result.status, output: result.output) ? nil : .notSignedIn(cli)
        }

        /// The models the agent offers, `nil` when they cannot be read (the model is then typed).
        public func models() async -> [Model]? {
            if let fixed = cli.fixedModels { return fixed }
            guard let executable = locate(), let place = try? Place(cli, environment: environment) else { return nil }
            defer { place.remove() }
            // Copilot stops before fetching its catalog without a prompt; it never gets to send it.
            guard let arguments = cli.modelListArguments(folder: place.folder),
                  let result = try? await run(executable, arguments, in: place, input: Data("OK".utf8), timeout: .seconds(60)),
                  result.ending == .exited,
                  let listing = cli.modelListing(output: result.output, status: result.status, scratch: place.scratch)
            else { return nil }
            let models = cli.models(fromListing: listing)
            return models.isEmpty ? nil : models
        }

        private func complete(
            _ request: URLRequest, model: String, reasoning: ProviderProfile.ReasoningEffort?
        ) async throws -> (Data, HTTPURLResponse) {
            guard let executable = locate() else { throw Failure.notInstalled(cli) }
            guard !model.isEmpty || cli.hasDefaultModel else { throw Failure.noModel(cli) }
            guard !model.hasPrefix("-") else { throw Failure.invalidModel(cli, model) }
            let (instructions, prompt) = try AppleIntelligence.conversation(fromRequestBody: request.httpBody ?? Data())
            let input = cli.input(instructions: instructions, prompt: prompt)
            Place.removeLeftovers()
            let place = try Place(cli, environment: environment)
            defer { place.remove() }
            if cli == .opencode { await deleteLeftoverSessions(executable) }

            let started = ContinuousClock.now
            log("LLM request through \(cli.name), model \(model.isEmpty ? "default" : model), \(input.utf8.count) bytes")
            let result = try await run(
                executable, cli.arguments(model: model, reasoning: reasoning, folder: place.folder),
                in: place, input: Data(input.utf8), timeout: timeout
            )
            let outcome = cli.outcome(ofEvents: result.output)
            // Also after a timeout or *Stop processing*: the session holds part of the Meeting.
            if let session = outcome.session, cli == .opencode {
                await Task.detached { await deleteSession(session, executable) }.value
            }
            let seconds = ((ContinuousClock.now - started) / .seconds(1)).formatted(.number.precision(.fractionLength(1)))
            log("LLM reply through \(cli.name) in \(seconds) s: \(result.ending), exit \(result.status), model \(outcome.model ?? "not reported"), \(outcome.usage), \(outcome.toolCalls) tool calls")

            switch result.ending {
            case .cancelled: throw CancellationError()
            case .timedOut: throw Failure.timedOut(cli)
            case .exited: break
            }
            // One line of what the CLI printed: the rest can hold the request's text.
            let printed = cli.reason(inPrinted: String(decoding: result.errors, as: UTF8.self))
            if outcome.reply == nil || result.status != 0 {
                let reason = outcome.failure ?? printed ?? "exit \(result.status)"
                // Not what it printed: that can hold the request's text.
                log("\(cli.name) failed: \(outcome.failure ?? "exit \(result.status)")")
                let signIn = ["login", "log in", "sign in", "signed in", "authenticat", "no api key"].contains { reason.localizedCaseInsensitiveContains($0) }
                if signIn { throw Failure.notSignedIn(cli) }
                if outcome.failure != nil || result.status != 0 { throw Failure.failed(cli, reason) }
            }
            guard let reply = outcome.reply?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else {
                throw Failure.emptyReply(cli)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (cli.responseBody(reply, outcome: outcome), response)
        }

        /// Before a run, the sessions earlier runs left in OpenCode (Takku quit or the Mac slept
        /// during one): only those older than a run can last, so none still going is touched.
        private func deleteLeftoverSessions(_ executable: URL) async {
            guard let result = try? await runAside(executable, ["session", "list", "--standalone", "--format", "json"], timeout: .seconds(60)),
                  result.ending == .exited, result.status == 0
            else { return }
            let finished = Date.now.addingTimeInterval(-(timeout / .seconds(1)) - 300)
            for session in cli.leftoverSessions(inListing: result.output, folder: Place.openCodeFolder, createdBefore: finished) {
                await deleteSession(session, executable)
            }
        }

        private func deleteSession(_ session: String, _ executable: URL) async {
            _ = try? await runAside(executable, ["session", "delete", "--standalone", session], timeout: .seconds(60))
        }

        /// A short run that is not a request (sign-in, models, sessions), in a place of its own.
        private func runAside(_ executable: URL, _ arguments: [String], timeout: Duration) async throws -> Result {
            let place = try Place(cli, environment: environment)
            defer { place.remove() }
            return try await run(executable, arguments, in: place, input: Data(), timeout: timeout)
        }

        private struct Result {
            enum Ending { case exited, timedOut, cancelled }
            var ending: Ending
            var status: Int32
            var output: Data
            var errors: Data
        }

        /// Runs `executable` to the end, its input and outputs through files (no pipe can fill up
        /// and block it). What it printed comes back also when it timed out or was cancelled.
        private func run(_ executable: URL, _ arguments: [String], in place: Place, input: Data, timeout: Duration) async throws -> Result {
            let inputFile = place.scratch.appending(path: "in"), outputFile = place.scratch.appending(path: "out")
            let errorFile = place.scratch.appending(path: "err")
            try input.write(to: inputFile)
            FileManager.default.createFile(atPath: outputFile.path, contents: nil)
            FileManager.default.createFile(atPath: errorFile.path, contents: nil)
            func printed(_ status: Int32, _ ending: Result.Ending) -> Result {
                Result(
                    ending: ending, status: status,
                    output: (try? Data(contentsOf: outputFile)) ?? Data(), errors: (try? Data(contentsOf: errorFile)) ?? Data()
                )
            }
            if Task.isCancelled { return printed(-1, .cancelled) }

            nonisolated(unsafe) let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = place.folder
            var environment = self.environment.filter { !AgentCLI.isRemoved($0.key) }.merging(cli.environment(scratch: place.scratch)) { $1 }
            // An npm install is a Node script: Node must be on the PATH a Mac app does not have.
            environment["PATH"] = executable.deletingLastPathComponent().path + ":" + Hook.path(adding: environment["PATH"])
            process.environment = environment
            process.standardInput = try FileHandle(forReadingFrom: inputFile)
            process.standardOutput = try FileHandle(forWritingTo: outputFile)
            process.standardError = try FileHandle(forWritingTo: errorFile)

            let timedOut = OSAllocatedUnfairLock(initialState: false)
            let watchdog = Task {
                try await Task.sleep(for: timeout)
                if process.isRunning {
                    timedOut.withLock { $0 = true }
                    Self.stop(process)
                }
            }
            defer { watchdog.cancel() }
            let status: Int32 = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                    do { try process.run() } catch {
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                        return
                    }
                    // Cancelled while it was starting: the handler found nothing to stop.
                    if Task.isCancelled { Self.stop(process) }
                }
            } onCancel: {
                if process.isRunning { Self.stop(process) }
            }
            if Task.isCancelled { return printed(status, .cancelled) }
            return printed(status, timedOut.withLock { $0 } ? .timedOut : .exited)
        }

        /// Asks the process and what it started to end (Process runs it in a group of its own), and
        /// kills the group if it has not a few seconds later.
        private static func stop(_ process: Process) {
            process.terminate()
            let group = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { kill(-group, SIGKILL) }
        }
    }

    /// Where a run happens: an empty folder to run in, and next to it a scratch folder for its
    /// input and output and whatever else the CLI needs; the scratch folder goes after the run.
    private struct Place {
        /// OpenCode lists sessions by the folder they ran in: its runs share one, always empty,
        /// so that the sessions earlier runs left behind can be found.
        static let openCodeFolder = FileManager.default.temporaryDirectory.appending(path: "Takku-opencode-work")

        let scratch: URL
        let folder: URL

        init(_ cli: AgentCLI, environment: [String: String]) throws {
            scratch = FileManager.default.temporaryDirectory.appending(path: "Takku-\(cli.rawValue)-\(UUID().uuidString)")
            folder = cli == .opencode ? Self.openCodeFolder : scratch.appending(path: "work")
            for subfolder in ["home", "config", "state", "cache"] {
                try FileManager.default.createDirectory(at: scratch.appending(path: subfolder), withIntermediateDirectories: true)
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            cli.prepare(scratch: scratch, environment: environment)
        }

        func remove() {
            try? FileManager.default.removeItem(at: scratch)
        }

        /// The scratch folders of runs cut short (Takku quit, the Mac slept), which hold a request:
        /// older than any run can last.
        static func removeLeftovers() {
            let fileManager = FileManager.default
            let prefixes = AgentCLI.allCases.map { "Takku-\($0.rawValue)-" }
            let folders = (try? fileManager.contentsOfDirectory(
                at: fileManager.temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for folder in folders where folder != openCodeFolder && prefixes.contains(where: folder.lastPathComponent.hasPrefix) {
                let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < Date.now.addingTimeInterval(-3600) { try? fileManager.removeItem(at: folder) }
            }
        }
    }

    // MARK: - Finding the executable

    /// Where the CLI usually is, as installed by Homebrew, npm, bun, volta or the agent's own
    /// installer: a Mac app does not get the PATH of the user's shell.
    func candidatePaths(home: URL) -> [String] {
        let folders = ["/opt/homebrew/bin", "/usr/local/bin"]
            + [".local/bin", ".npm-global/bin", ".bun/bin", ".volta/bin", ".opencode/bin"].map { home.appending(path: $0).path }
        // nvm: its default Node first, then the newest.
        let nvm = home.appending(path: ".nvm")
        let installed = ((try? FileManager.default.contentsOfDirectory(atPath: nvm.appending(path: "versions/node").path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        let alias = ((try? String(contentsOf: nvm.appending(path: "alias/default"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let version = alias.hasPrefix("v") ? alias : "v" + alias
        let isDefault = { (name: String) in !alias.isEmpty && (name == version || name.hasPrefix(version + ".")) }
        let versions = (installed.filter(isDefault) + installed.filter { !isDefault($0) })
            .map { nvm.appending(path: "versions/node/\($0)/bin").path }
        return (folders + versions).map { "\($0)/\(command)" }
    }

    /// The CLI's executable: in the usual places, else where the user's login shell finds it;
    /// `nil` if neither has it.
    func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let fileManager = FileManager.default
        if let path = candidatePaths(home: home).first(where: fileManager.isExecutableFile) {
            return URL(filePath: path)
        }
        let shell = Process()
        shell.executableURL = URL(filePath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        shell.arguments = ["-lc", "command -v \(command)"]
        // A file, not a pipe: a login script's child holding a pipe open would keep it from ending.
        let outputFile = fileManager.temporaryDirectory.appending(path: "Takku-locate-\(UUID().uuidString)")
        fileManager.createFile(atPath: outputFile.path, contents: nil)
        defer { try? fileManager.removeItem(at: outputFile) }
        guard let output = try? FileHandle(forWritingTo: outputFile) else { return nil }
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        shell.standardInput = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        shell.terminationHandler = { _ in ended.signal() }
        guard (try? shell.run()) != nil else { return nil }
        // A login script that waits for input would hold the run forever.
        if ended.wait(timeout: .now() + 10) == .timedOut {
            shell.terminate()
            return nil
        }
        let found = ((try? String(contentsOf: outputFile, encoding: .utf8)) ?? "")
            .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        guard shell.terminationStatus == 0, let found, found.hasPrefix("/"), fileManager.isExecutableFile(atPath: found) else { return nil }
        return URL(filePath: found)
    }
}
