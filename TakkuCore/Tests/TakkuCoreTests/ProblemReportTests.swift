import Foundation
import Testing
import TakkuCore

@Suite("Report a problem")
struct ProblemReportTests {
    let report = ProblemReport(
        version: "0.3.1 (10)", system: "macOS 26.0.1, Mac14,2, 16 GB", installedWith: "Homebrew",
        transcriptionModel: "Large v3 Turbo", summary: "gemma4-31b (remote)"
    )

    func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test("the issue link opens the bug form with the fields filled in")
    func issueURL() {
        let url = report.issueURL
        #expect(url.absoluteString.hasPrefix("https://github.com/mameli/Takku/issues/new?"))
        #expect(query(url) == [
            "template": "bug_report.yml", "version": "0.3.1 (10)", "macos": "macOS 26.0.1, Mac14,2, 16 GB",
            "install": "Homebrew", "model": "Large v3 Turbo", "summary": "gemma4-31b (remote)",
        ])
    }

    @Test("an unknown install method is left for the user to choose")
    func unknownInstall() {
        var report = report
        report.installedWith = nil
        #expect(query(report.issueURL)["install"] == nil)
    }

    @Test("values with spaces, commas and parentheses survive the link")
    func encoding() {
        #expect(!report.issueURL.absoluteString.contains(" "))
    }

    @Test("the file lists the same fields, a warning to check it, then the logs")
    func text() {
        let text = report.text(logs: "2026-10-10 E Takku[1] failed")
        #expect(text.contains("Check this file before attaching it"))
        #expect(text.contains("Takku: 0.3.1 (10)"))
        #expect(text.contains("Installed with: Homebrew"))
        #expect(text.contains("Summary: gemma4-31b (remote)"))
        #expect(text.hasSuffix("2026-10-10 E Takku[1] failed\n"))
    }

    @Test("the Summary is described by model and where it runs, never by address or name")
    func summary() {
        let local = ProviderProfile(name: "Laptop", baseURL: "http://localhost:8080/v1", model: "gemma", maxContextTokens: 32_000)
        let remote = ProviderProfile(name: "ACME", baseURL: "https://llm.acme.internal/v1", model: "qwen", maxContextTokens: 32_000)
        #expect(ProblemReport.summary(of: nil) == "Transcript only")
        #expect(ProblemReport.summary(of: local) == "gemma (on this Mac)")
        #expect(ProblemReport.summary(of: remote) == "qwen (remote)")
    }

    @Test("the logs in the file hide an address and a path a log call left public")
    func logsAreRedacted() {
        let report = ProblemReport(version: "1.0 (1)", system: "macOS", installedWith: nil, transcriptionModel: "m", summary: "x (remote)")
        let text = report.text(logs: """
            error Summary not generated: the address https://llm.acme-corp.example/v1 is not secure
            error Hook failed: /Users/mario/Vault/Meeting with Acme.md: no such file
            error Rename failed: file:///Volumes/Work/Meetings/2026-10-10 Acme.md and /private/tmp/Acme renewal.md moved
            notice LLM reply HTTP 200, 1200 bytes in 3.1 s
            """)

        #expect(!text.contains("acme-corp"))
        #expect(!text.contains("Meeting with Acme"))
        #expect(!text.contains("/Users/mario") && !text.contains("/Volumes") && !text.contains("/private") && !text.contains("Acme renewal"))
        #expect(text.contains("LLM reply HTTP 200, 1200 bytes in 3.1 s"))
    }

    @Test("an error is logged by its domain and code, not by its text")
    func logCode() {
        let error = CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: "/Users/mario/Vault/Acme renewal.md"])
        #expect(error.logCode == "NSCocoaErrorDomain 260")
        #expect(!error.logCode.contains("Acme"))
    }
}
