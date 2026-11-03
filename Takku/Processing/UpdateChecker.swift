import AppKit
import Observation
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "updates")

/// At launch and once a day, when the user leaves it on in Settings, asks GitHub for the latest
/// release. The request carries nothing about the user or the Meetings.
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Equatable {
        let version: String
    }

    private static let latestRelease = URL(string: "https://api.github.com/repos/mameli/Takku/releases/latest")!
    /// How to update, step by step: not GitHub's release page, which puts off those who never saw GitHub.
    private static let updatePage = URL(string: "https://takku.app/update")!

    /// A release newer than the running app, shown in the menu.
    private(set) var available: Release?

    func start() {
        Task { [weak self] in
            while true {
                guard let self else { return }
                if AppSettings.checkForUpdates { await self.check() }
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    func openUpdatePage() {
        NSWorkspace.shared.open(Self.updatePage)
    }

    private func check() async {
        struct Reply: Decodable {
            let tag: String

            enum CodingKeys: String, CodingKey {
                case tag = "tag_name"
            }
        }
        var request = URLRequest(url: Self.latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            guard let version = AppVersion.fromTag(reply.tag), AppVersion.isNewer(version, than: current) else {
                available = nil
                return
            }
            available = Release(version: version)
        } catch {
            // Offline or rate-limited: nothing to show, tried again tomorrow.
            logger.notice("Update check failed: \(error, privacy: .public)")
        }
    }
}
