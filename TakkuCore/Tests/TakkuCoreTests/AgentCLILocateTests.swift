import Foundation
import Testing
@testable import TakkuCore

@Suite("Finding an agent's CLI")
struct AgentCLILocateTests {
    /// A home, an install of the CLI outside the usual places (as OpenCode's installer puts it in
    /// `~/.opencode/bin`, on the PATH only from `.zshrc`), and a stand-in for the user's shell.
    final class Mac {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Takku-locate-test-\(UUID().uuidString)")
        var home: URL { folder.appending(path: "home") }
        var elsewhere: URL { folder.appending(path: "elsewhere") }
        var shell: URL { folder.appending(path: "shell") }
        var shellArguments: [String] {
            ((try? String(contentsOf: folder.appending(path: "shell-args"), encoding: .utf8)) ?? "")
                .split(separator: "\0").map(String.init)
        }

        /// `startup` runs before the command, as `.zshrc` does: by default it prints a line and
        /// puts `elsewhere` on the PATH.
        init(_ cli: AgentCLI, startup: String? = nil) throws {
            let startup = startup ?? "echo 'Last login: Tue Nov 4 on ttys001'; echo /not/it; PATH='\(elsewhere.path)':$PATH"
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try Self.executable("#!/bin/sh\necho \(cli.rawValue)", at: elsewhere.appending(path: cli.command))
            try Self.executable("""
                #!/bin/bash
                printf '%s\\0' "$@" > '\(folder.appending(path: "shell-args").path)'
                PATH=/usr/bin:/bin
                \(startup)
                exec /bin/bash -c "$2"
                """, at: shell)
        }

        deinit {
            try? FileManager.default.removeItem(at: folder)
        }

        static func executable(_ script: String, at url: URL) throws {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    @Test("the CLI the user's shell runs, as Terminal starts it, wins over another install in the usual places")
    func shellFirst() async throws {
        let mac = try Mac(.opencode)

        let found = await AgentCLI.opencode.locate(home: mac.home, shell: mac.shell)

        #expect(found?.path == mac.elsewhere.appending(path: "opencode").path)
        // Interactive and login: installers add to the PATH in .zshrc.
        #expect(mac.shellArguments.first == "-ilc")
        #expect(mac.shellArguments.last?.contains("command -v opencode") == true)
    }

    @Test("with the shell finding none, a shell function, or a shell that does not end, the usual places", arguments: [
        "true", "claude() { :; }; export -f claude", "sleep 30",
    ])
    func usualPlaces(startup: String) async throws {
        let mac = try Mac(.claude, startup: startup)
        let usual = mac.home.appending(path: ".local/bin/claude")
        try FileManager.default.createDirectory(at: usual.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Mac.executable("#!/bin/sh\necho claude", at: usual)
        let expected = AgentCLI.claude.candidatePaths(home: mac.home).first(where: FileManager.default.isExecutableFile)

        let started = ContinuousClock.now
        let found = await AgentCLI.claude.locate(home: mac.home, shell: mac.shell, timeout: .milliseconds(500))

        #expect(found?.path == expected)
        #expect(found?.path != mac.elsewhere.appending(path: "claude").path)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("the version in what each CLI prints for --version", arguments: [
        ("codex-cli 0.163.0", "0.163.0"),
        ("GitHub Copilot CLI 1.0.105.\nRun 'copilot update' to check for updates.", "1.0.105"),
        ("2.1.282 (Claude Code)", "2.1.282"),
        ("opencode v2.2.5", "2.2.5"),
        ("1.5.0", "1.5.0"),
        ("no version here", nil),
    ])
    func version(printed: String, expected: String?) {
        #expect(AgentCLI.version(in: printed) == expected)
    }

    @Test("the version comes from a run of the CLI found")
    func versionFromRun() async throws {
        let fake = try FakeCLI(.opencode, [.init(pattern: "--version", script: FakeCLI.prints("opencode v2.2.5"))])

        #expect(await fake.runner().version() == "2.2.5")
    }
}
