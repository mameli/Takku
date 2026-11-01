import Foundation
import TakkuCore

/// `Takku mcp [--notes-folder PATH]`: serves the Meetings of the notes folder to an agent over
/// MCP on stdin and stdout, without starting the app (no menu, no recording), until stdin closes.
/// The notes folder is the one chosen in Settings unless `--notes-folder` gives another.
enum MCPCommand {
    static let argument = "mcp"

    static func runIfRequested() {
        let arguments = CommandLine.arguments.dropFirst()
        guard arguments.first == argument else { return }
        let folder = arguments.firstIndex(of: "--notes-folder")
            .flatMap { arguments.index(after: $0) < arguments.endIndex ? arguments[arguments.index(after: $0)] : nil }
            ?? AppSettings.vaultPath
        let library = folder.map { MeetingLibrary(notesFolder: URL(filePath: $0, directoryHint: .isDirectory)) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        MCPServer(library: library, version: version).run(
            readLine: { Swift.readLine(strippingNewline: true) },
            write: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }
        )
        exit(0)
    }
}
