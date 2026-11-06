import AppKit
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "report")

/// *Report a problem…*: writes a report file with Takku's version, the Mac, the settings that
/// matter and Takku's logs of the last days, shows it in Finder and opens the GitHub bug form
/// with the same fields filled in. Nothing is sent: the user checks the file and attaches it.
@MainActor
enum ProblemReporter {
    private nonisolated static let logDays = 3

    static func report() {
        let report = ProblemReport(
            version: version, system: system, installedWith: installedWith,
            transcriptionModel: TranscriptionModel.selected.name,
            summary: ProblemReport.summary(of: AppSettings.activeProviderProfile)
        )
        Task {
            let logs = await recentLogs()
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
            // The temporary folder: Desktop and Downloads would need a permission of their own.
            let file = URL.temporaryDirectory.appending(path: "Takku report \(stamp.string(from: .now)).txt")
            do {
                try report.text(logs: logs).write(to: file, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } catch {
                logger.error("Report not written: \(error.logCode, privacy: .public) \(error, privacy: .private)")
            }
            NSWorkspace.shared.open(report.issueURL)
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// "macOS 26.0.1, Mac14,2, 16 GB".
    private static var system: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        return "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(String(cString: model)), \(memory) GB"
    }

    private static var installedWith: String? {
        #if DEBUG
        return "Built from source"
        #else
        let caskroom = ["/opt/homebrew/Caskroom/takku", "/usr/local/Caskroom/takku"]
        return caskroom.contains { FileManager.default.fileExists(atPath: $0) } ? "Homebrew" : nil
        #endif
    }

    /// What `log show` keeps of Takku's messages: errors and notices are stored for days, info
    /// only while in memory. Values not marked public show as `<private>`.
    private static func recentLogs() async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/log")
            process.arguments = [
                "show", "--last", "\(logDays)d", "--info", "--style", "compact",
                "--predicate", #"subsystem == "app.takku.takku""#,
            ]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                // Read before waiting: a full pipe would block `log` forever.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return String(decoding: data, as: UTF8.self)
            } catch {
                return "Logs not available: \(error)"
            }
        }.value
    }
}
