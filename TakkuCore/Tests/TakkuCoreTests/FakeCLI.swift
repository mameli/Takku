import Foundation
import TakkuCore

/// A stand-in for an agent's CLI: a shell script that records what each run got (arguments,
/// environment, standard input, folder) and answers with the first rule whose pattern matches its
/// arguments, as recorded from real runs.
final class FakeCLI {
    struct Rule {
        /// A shell `case` pattern on the arguments joined by spaces, e.g. `"*debug models*"`.
        var pattern: String
        /// Shell code that prints the answer and exits.
        var script: String
    }

    struct Call {
        var arguments: [String]
        var environment: [String: String]
        var input: String
        /// Where it ran, symbolic links resolved, and what was in there.
        var folder: String
        var files: String
        var pid: Int32?

        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }

        /// Whether `path` is the folder it ran in (gone by now: /var is /private/var by hand).
        func ranIn(_ path: String?) -> Bool {
            func physical(_ path: String) -> String { path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path }
            return path.map(physical) == physical(folder)
        }
    }

    let folder: URL
    let executable: URL

    init(_ cli: AgentCLI, _ rules: [Rule]) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "Takku-fake-\(UUID().uuidString)")
        executable = folder.appending(path: "bin/\(cli.rawValue)")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cases = rules.map { "\($0.pattern.replacingOccurrences(of: " ", with: "\\ ")))\n\($0.script)\n;;" }.joined(separator: "\n")
        let script = """
            #!/bin/bash
            calls='\(folder.appending(path: "calls").path)'
            mkdir -p "$calls"
            call="$calls/$(ls "$calls" | wc -l | tr -d ' ')"
            mkdir "$call"
            printf '%s\\0' "$@" > "$call/args"
            env -0 > "$call/env"
            pwd -P > "$call/folder"
            ls -A > "$call/files"
            cat > "$call/input"
            echo $$ > "$call/pid"
            case "$*" in
            \(cases)
            *)
            echo "no rule for: $*" >&2
            exit 99
            ;;
            esac
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    var calls: [Call] {
        let root = folder.appending(path: "calls")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).compactMap(Int.init).sorted()
        return names.map { name in
            let call = root.appending(path: String(name))
            func read(_ file: String) -> String { (try? String(contentsOf: call.appending(path: file), encoding: .utf8)) ?? "" }
            let fields = { (text: String) in text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init) }
            var arguments = fields(read("args"))
            if arguments.last == "" { arguments.removeLast() }
            let environment = Dictionary(fields(read("env")).compactMap { entry -> (String, String)? in
                guard let equals = entry.firstIndex(of: "=") else { return nil }
                return (String(entry[..<equals]), String(entry[entry.index(after: equals)...]))
            }, uniquingKeysWith: { $1 })
            return Call(
                arguments: arguments, environment: environment, input: read("input"),
                folder: read("folder").trimmingCharacters(in: .newlines), files: read("files"),
                pid: Int32(read("pid").trimmingCharacters(in: .whitespacesAndNewlines))
            )
        }
    }

    /// The runs whose arguments start with `prefix`.
    func calls(startingWith prefix: [String]) -> [Call] {
        calls.filter { $0.arguments.starts(with: prefix) }
    }

    func runner(
        environment: [String: String] = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], timeout: Duration = .seconds(30)
    ) -> AgentCLI.Runner {
        let executable = executable
        guard let cli = AgentCLI(rawValue: executable.lastPathComponent) else { fatalError("not an agent CLI") }
        return AgentCLI.Runner(cli, locate: { executable }, environment: environment, timeout: timeout)
    }

    static func prints(_ text: String, exit status: Int32 = 0) -> String {
        "cat <<'TAKKU_EOF'\n\(text)\nTAKKU_EOF\nexit \(status)"
    }
}
