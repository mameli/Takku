import Foundation
import TakkuCore

/// `takku list|search|get|mcp …` (the link Homebrew puts in its bin folder) or
/// `Takku.app/Contents/MacOS/Takku list|search|get|mcp …`: runs `MeetingCommand` on the notes
/// folder chosen in Settings, without starting the app (no menu, no recording), and exits. Run as
/// `takku`, every argument goes to the command, so a mistyped one prints the usage instead of
/// starting the app; run as `Takku`, any other first argument, or none, starts the app as usual.
enum TerminalCommand {
    static func runIfRequested() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let calledTakku = URL(filePath: CommandLine.arguments[0]).lastPathComponent == "takku"
        guard calledTakku || arguments.first.map(MeetingCommand.names.contains) == true else { return }
        runFromBundleIfLinked()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let status = MeetingCommand(arguments: arguments, notesFolder: AppSettings.vaultPath, version: version).run(
            readLine: { Swift.readLine(strippingNewline: true) },
            output: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
            error: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        )
        exit(status)
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
