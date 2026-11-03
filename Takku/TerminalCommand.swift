import AppKit
import TakkuCore

/// `takku list|search|get|import|… …` (the link Homebrew puts in its bin folder) or
/// `Takku.app/Contents/MacOS/Takku list|search|get|import|… …`: runs `MeetingCommand` on the notes
/// folder chosen in Settings, without starting the app (no menu, no recording), and exits; `import`
/// and `regenerate` ask the app, opening it if needed (ADR 0015). Run as
/// `takku`, every argument goes to the command, so a mistyped one prints the usage instead of
/// starting the app; run as `Takku`, any other first argument, or none, starts the app as usual.
enum TerminalCommand {
    static func runIfRequested() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let calledTakku = URL(filePath: CommandLine.arguments[0]).lastPathComponent == "takku"
        guard calledTakku || arguments.first.map(MeetingCommand.names.contains) == true else { return }
        runFromBundleIfLinked()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let state = TakkuState(
            templates: TakkuFolder.templateNames(), defaultTemplate: AppSettings.defaultTemplate,
            profiles: AppSettings.summaryProfiles, activeProfileID: AppSettings.activeProviderProfileID,
            recordingsFolder: MeetingRecorder.recordingsDirectory, noteFolders: AppSettings.noteFolders
        )
        let command = MeetingCommand(
            arguments: arguments, notesFolder: AppSettings.vaultPath, version: version, state: state,
            requests: MeetingController.requestFolder, app: appLink
        )
        let status = command.run(
            readLine: { Swift.readLine(strippingNewline: true) },
            output: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
            error: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        )
        exit(status)
    }

    /// The menu bar app, told apart from other `takku` commands running from the same bundle: those
    /// never become apps with a menu (their activation policy stays prohibited).
    private static var appLink: MeetingCommand.AppLink {
        MeetingCommand.AppLink(
            isRunning: { isAppRunning() },
            open: {
                guard !isAppRunning() else { return }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.addsToRecentItems = false
                configuration.promptsUserIfNeeded = false
                let opened = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var failure: Error?
                NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
                    failure = error
                    opened.signal()
                }
                if opened.wait(timeout: .now() + 30) == .timedOut {
                    throw CocoaError(.executableLoad)
                }
                if let failure { throw failure }
            },
            pause: { Thread.sleep(forTimeInterval: $0) }
        )
    }

    private static func isAppRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { app in
            app.processIdentifier != getpid() && !app.isTerminated && app.activationPolicy != .prohibited
        }
    }

    /// Started through a link, the executable does not find its bundle, and with it the Settings
    /// (the notes folder) and the version: it runs again from its path inside Takku.app.
    private static func runFromBundleIfLinked() {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var path = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&path, &size) == 0 else { return }
        let started = String(cString: path)
        let resolved = URL(filePath: started).resolvingSymlinksInPath().path(percentEncoded: false)
        guard resolved != started else { return }
        execv(resolved, CommandLine.unsafeArgv)
    }
}
