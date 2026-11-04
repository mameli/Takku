import Foundation
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "summary")

/// The Codex CLI the user installed and signed in to: where it is, whether it is signed in, and the
/// `ChatClient` transport that runs `codex exec` for each request (see `Codex`). Takku never signs
/// in for the user: that stays `codex login`, in Terminal.
enum CodexModel {
    enum Unavailable: LocalizedError, Equatable {
        case notInstalled, notSignedIn, timedOut, emptyReply
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                String(localized: "Codex is not installed: install it (brew install codex), then sign in with codex login in Terminal.")
            case .notSignedIn:
                String(localized: "Codex is not signed in: run codex login in Terminal, then try again.")
            case .timedOut:
                String(localized: "Codex did not answer within 15 minutes.")
            case .emptyReply:
                String(localized: "Codex finished without writing anything.")
            case .failed(let reason):
                String(localized: "Codex: \(reason)")
            }
        }
    }

    /// A run that hangs gives up after this long, as a remote provider does.
    private static let timeout: Duration = .seconds(900)

    /// The `codex` executable: in the usual places, else where the user's login shell finds it
    /// (nvm and the like); `nil` if neither has it.
    static func executable() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        if let path = Codex.candidatePaths(home: home).first(where: fileManager.isExecutableFile) {
            return URL(filePath: path)
        }
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v codex"]
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

    /// Why Codex cannot be used now, `nil` when it can: installed and signed in.
    static func unavailability() async -> Unavailable? {
        guard let codex = executable() else { return .notInstalled }
        let result = try? await run(codex, arguments: ["login", "status"], input: Data(), timeout: .seconds(30))
        return result?.status == 0 ? nil : .notSignedIn
    }

    /// A client for the Profile: each request is one run of `codex exec`.
    static func client(profile: ProviderProfile) -> ChatClient {
        let model = profile.model
        let reasoning = profile.reasoning
        return ChatClient(baseURL: URL(string: Codex.baseURL)!, apiKey: nil, model: model.isEmpty ? Codex.name : model) { request in
            guard let codex = executable() else { throw Unavailable.notInstalled }
            let folder = FileManager.default.temporaryDirectory.appending(path: "Takku-Codex-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            let input = try Codex.input(fromRequestBody: request.httpBody ?? Data())
            let started = ContinuousClock.now
            logger.notice("LLM request through Codex, model \(model.isEmpty ? "default" : model, privacy: .public), \(input.utf8.count) bytes")
            let result = try await run(
                codex, arguments: Codex.arguments(model: model, reasoning: reasoning, folder: folder),
                input: Data(input.utf8), in: folder, timeout: timeout
            )
            let outcome = Codex.outcome(ofEvents: result.output)
            logger.notice("LLM reply through Codex in \(secondsSince(started), privacy: .public): exit \(result.status), \(outcome.inputTokens) tokens in, \(outcome.outputTokens) out, \(outcome.toolCalls) tool calls")

            if let failure = outcome.failure, outcome.reply == nil {
                logger.error("Codex failed: \(failure, privacy: .public)")
                throw failure.localizedCaseInsensitiveContains("login") || failure.localizedCaseInsensitiveContains("auth")
                    ? Unavailable.notSignedIn : Unavailable.failed(failure)
            }
            guard result.status == 0 else {
                // Only the last line: the rest of what Codex prints can hold the request's text.
                let reason = String(decoding: result.errors, as: UTF8.self)
                    .split(separator: "\n").last.map(String.init) ?? "exit \(result.status)"
                logger.error("Codex exited with \(result.status)")
                throw reason.localizedCaseInsensitiveContains("login") ? Unavailable.notSignedIn : Unavailable.failed(reason)
            }
            guard let reply = outcome.reply?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else {
                throw Unavailable.emptyReply
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Codex.responseBody(reply), response)
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
        _ executable: URL, arguments: [String], input: Data, in folder: URL? = nil, timeout: Duration
    ) async throws -> Result {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "Takku-Codex-io-\(UUID().uuidString)")
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
        var environment = ProcessInfo.processInfo.environment
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
        if timedOut.withLock({ $0 }) { throw Unavailable.timedOut }
        return Result(status: status, output: (try? Data(contentsOf: outputFile)) ?? Data(), errors: (try? Data(contentsOf: errorFile)) ?? Data())
    }
}
