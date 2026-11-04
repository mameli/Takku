import Foundation
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "summary")

/// A coding agent's CLI the user installed and signed in to (see `AgentCLI`): where it is, whether
/// it is signed in, and the `ChatClient` transport that runs it once for each request. Takku never
/// signs in for the user: that stays the CLI's own login, in Terminal.
enum AgentCLIModel {
    enum Unavailable: LocalizedError, Equatable {
        case notInstalled(AgentCLI), notSignedIn(AgentCLI), timedOut(AgentCLI), emptyReply(AgentCLI)
        case failed(AgentCLI, String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(.codex):
                String(localized: "Codex is not installed: install it (brew install codex), then sign in with codex login in Terminal.")
            case .notInstalled(.copilot):
                String(localized: "GitHub Copilot CLI is not installed: install it (brew install --cask copilot-cli), then sign in with copilot login in Terminal.")
            case .notSignedIn(let cli):
                String(localized: "\(cli.name) is not signed in: run \(cli.command) login in Terminal, then try again.")
            case .timedOut(let cli):
                String(localized: "\(cli.name) did not answer within 15 minutes.")
            case .emptyReply(let cli):
                String(localized: "\(cli.name) finished without writing anything.")
            case .failed(let cli, let reason):
                String(localized: "\(cli.name): \(reason)")
            }
        }
    }

    /// A run that hangs gives up after this long, as a remote provider does.
    private static let timeout: Duration = .seconds(900)

    /// The CLI's executable: in the usual places, else where the user's login shell finds it (nvm
    /// and the like); `nil` if neither has it.
    static func executable(_ cli: AgentCLI) -> URL? {
        let fileManager = FileManager.default
        if let path = cli.candidatePaths(home: fileManager.homeDirectoryForCurrentUser).first(where: fileManager.isExecutableFile) {
            return URL(filePath: path)
        }
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v \(cli.command)"]
        let output = Pipe()
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        shell.standardInput = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let found = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        guard shell.terminationStatus == 0, let found, found.hasPrefix("/"), fileManager.isExecutableFile(atPath: found) else { return nil }
        return URL(filePath: found)
    }

    /// Why the CLI cannot be used now, `nil` when it can as far as can be told without a run:
    /// installed and, for Codex, signed in (Copilot has no command that says so).
    static func unavailability(_ cli: AgentCLI) async -> Unavailable? {
        guard let executable = executable(cli) else { return .notInstalled(cli) }
        guard cli == .codex else { return nil }
        let result = try? await run(executable, arguments: ["login", "status"], environment: [:], input: Data(), timeout: .seconds(30))
        return result?.status == 0 ? nil : .notSignedIn(cli)
    }

    /// A client for the Profile: each request is one run of the CLI.
    static func client(_ cli: AgentCLI, profile: ProviderProfile) -> ChatClient {
        let model = profile.model
        let reasoning = profile.reasoning
        return ChatClient(baseURL: URL(string: cli.baseURL)!, apiKey: nil, model: model.isEmpty ? cli.name : model) { request in
            guard let executable = executable(cli) else { throw Unavailable.notInstalled(cli) }
            // The run's empty folder, and next to it whatever else the CLI needs (Copilot's home).
            let scratch = FileManager.default.temporaryDirectory.appending(path: "Takku-\(cli.rawValue)-\(UUID().uuidString)")
            let folder = scratch.appending(path: "work")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }

            let input = try AgentCLI.input(fromRequestBody: request.httpBody ?? Data())
            let started = ContinuousClock.now
            logger.notice("LLM request through \(cli.name, privacy: .public), model \(model.isEmpty ? "default" : model, privacy: .public), \(input.utf8.count) bytes")
            let result = try await run(
                executable, arguments: cli.arguments(model: model, reasoning: reasoning, folder: folder),
                environment: cli.environment(folder: folder), input: Data(input.utf8), in: folder, timeout: timeout,
                onTimeout: .timedOut(cli)
            )
            let outcome = cli.outcome(ofEvents: result.output)
            logger.notice("LLM reply through \(cli.name, privacy: .public) in \(secondsSince(started), privacy: .public): exit \(result.status), \(outcome.usage, privacy: .public), \(outcome.toolCalls) tool calls")

            // Only the last line of what the CLI printed: the rest can hold the request's text.
            let printed = String(decoding: result.errors, as: UTF8.self).split(separator: "\n").last.map(String.init)
            if outcome.reply == nil || result.status != 0 {
                let reason = outcome.failure ?? printed ?? "exit \(result.status)"
                logger.error("\(cli.name, privacy: .public) failed: \(reason, privacy: .public)")
                let signIn = ["login", "log in", "sign in", "authenticat"].contains { reason.localizedCaseInsensitiveContains($0) }
                if signIn { throw Unavailable.notSignedIn(cli) }
                if outcome.failure != nil || result.status != 0 { throw Unavailable.failed(cli, reason) }
            }
            guard let reply = outcome.reply?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else {
                throw Unavailable.emptyReply(cli)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (cli.responseBody(reply), response)
        }
    }

    private struct Result {
        var status: Int32
        var output: Data
        var errors: Data
    }

    /// Runs `executable` to the end, its input and outputs through files (no pipe can fill up and
    /// block it). Cancelling the task, as *Stop processing* does, ends the process.
    private static func run(
        _ executable: URL, arguments: [String], environment extra: [String: String], input: Data, in folder: URL? = nil,
        timeout: Duration, onTimeout: Unavailable? = nil
    ) async throws -> Result {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "Takku-cli-io-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let inputFile = scratch.appending(path: "in"), outputFile = scratch.appending(path: "out"), errorFile = scratch.appending(path: "err")
        try input.write(to: inputFile)
        FileManager.default.createFile(atPath: outputFile.path, contents: nil)
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = folder }
        // An npm install is a Node script: Node must be on the PATH a Mac app does not have.
        var environment = ProcessInfo.processInfo.environment.merging(extra) { $1 }
        let path = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"]
        environment["PATH"] = path.joined(separator: ":")
        process.environment = environment
        process.standardInput = try FileHandle(forReadingFrom: inputFile)
        process.standardOutput = try FileHandle(forWritingTo: outputFile)
        process.standardError = try FileHandle(forWritingTo: errorFile)

        try Task.checkCancellation()
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            if process.isRunning {
                timedOut.withLock { $0 = true }
                process.terminate()
            }
        }
        defer { watchdog.cancel() }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        if timedOut.withLock({ $0 }) { throw onTimeout ?? CancellationError() }
        return Result(status: status, output: (try? Data(contentsOf: outputFile)) ?? Data(), errors: (try? Data(contentsOf: errorFile)) ?? Data())
    }
}
