import Foundation
import Synchronization
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "hook")

/// Runs the Hook (`~/.takku/hooks/after-processing`, ADR 0007) when a Meeting completes
/// Processing, with the paths of the Meeting note and of the Transcript. One at a time, in a
/// queue of its own: a slow Hook does not hold up the next Processing. Every run goes in the
/// log; a failure is also notified, and the Meeting stays completed.
@MainActor
final class HookRunner {
    static let shared = HookRunner()
    static var executableURL: URL { TakkuFolder.hooksFolder.appending(path: "after-processing") }
    static var logURL: URL { TakkuFolder.hooksFolder.appending(path: "after-processing.log") }

    /// Whether the user has put a Hook in place: its presence is what turns it on.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: executableURL.path(percentEncoded: false))
    }

    /// The last Hook in the queue: the next one starts when this one ends.
    private var queueTail: Task<Void, Never>?

    func run(note: URL, transcript: URL, vault: URL) {
        let executable = Self.executableURL
        let arguments = [note, transcript].map { $0.path(percentEncoded: false) }
        let noteName = note.deletingPathExtension().lastPathComponent
        let previous = queueTail
        queueTail = Task {
            await previous?.value
            let startedAt = Date()
            let (outcome, output) = await Self.execute(executable, arguments: arguments, in: vault)
            Self.appendToLog(Hook.logEntry(
                date: startedAt, noteName: noteName,
                command: Hook.command(executable: executable.path(percentEncoded: false), arguments: arguments),
                outcome: outcome, output: output
            ))
            guard outcome.failed else { return }
            logger.error("Hook failed for \(noteName, privacy: .private): \(String(describing: outcome), privacy: .public)")
            Notifications.shared.notify(
                title: String(localized: "Hook failed"),
                body: String(localized: "\(noteName): see ~/.takku/hooks/after-processing.log"),
                note: nil
            )
        }
    }

    /// Runs the Hook and returns how it ended with what it wrote on stdout and stderr, together.
    private nonisolated static func execute(
        _ executable: URL, arguments: [String], in directory: URL
    ) async -> (Hook.Outcome, String) {
        guard FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) else {
            return (.notExecutable, "")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Hook.path(adding: environment["PATH"])
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let output = Output()
        // Read while it runs: a full pipe would block the Hook forever.
        let endOfOutput = AsyncStream<Void> { continuation in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    output.append(data)
                }
            }
        }
        // Set before the start, so the end cannot be missed.
        let exit = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in continuation.finish() }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            // 126: the shell's code for a file that cannot be run (e.g. a script without `#!`).
            return (.exited(126), "Could not run the Hook: \(error.localizedDescription)")
        }
        // `Process` starts the Hook in a process group of its own (its pid), separate from
        // Takku's: signalling the group also stops what the Hook started in the background.
        let processGroup = process.processIdentifier
        let timedOut = Atomic(false)
        let timer = Task {
            try await Task.sleep(for: Hook.timeout)
            timedOut.store(true, ordering: .relaxed)
            kill(-processGroup, SIGTERM)
            try await Task.sleep(for: .seconds(5))
            kill(-processGroup, SIGKILL)
        }
        for await _ in exit {}
        // Once fired, the timer goes on to SIGKILL whatever ignored SIGTERM.
        if !timedOut.load(ordering: .relaxed) { timer.cancel() }

        // A child the Hook left in the background can keep the pipe open: wait for the rest
        // of the output for a moment only.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in endOfOutput {} }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
        }
        pipe.fileHandleForReading.readabilityHandler = nil

        let outcome: Hook.Outcome = timedOut.load(ordering: .relaxed) ? .timedOut : .exited(process.terminationStatus)
        return (outcome, output.text)
    }

    private static func appendToLog(_ entry: String) {
        let existing = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        do {
            try TakkuFolder.ensureFolder(TakkuFolder.hooksFolder)
            try Hook.trimmedLog(existing + entry).write(to: logURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Hook log not written: \(error.logCode, privacy: .public) \(error, privacy: .private)")
        }
    }

    /// What the Hook writes, up to the size of the log: more could never be kept anyway.
    private final class Output: Sendable {
        private let data = Mutex(Data())

        func append(_ chunk: Data) {
            data.withLock {
                $0.append(chunk)
                if $0.count > Hook.logLimit { $0.removeFirst($0.count - Hook.logLimit) }
            }
        }

        var text: String { data.withLock { String(decoding: $0, as: UTF8.self) } }
    }
}
