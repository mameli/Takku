import AppKit
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "vault")

/// Obsidian does not follow a note renamed under it: it closes the tab and shows the previous
/// note. When the user was looking at the Meeting note, Takku shows it again under its new name,
/// checking in `.obsidian/workspace.json` that Obsidian really shows it. Slow but correct: it
/// waits for Obsidian to notice the rename, and if Obsidian is not in front it waits for the user
/// to come back to it instead of bringing it forward in the middle of something else. Only for
/// Obsidian: Takku cannot tell what another Editor shows, and Zed follows the rename by itself.
@MainActor
enum RenamedNoteFollower {
    /// Time for Obsidian to notice the rename and save its layout.
    private static let settleTime: Duration = .seconds(3)
    private static let maxAttempts = 3
    /// After this long without the user coming back to Obsidian, Takku lets it go.
    private static let maxWait: TimeInterval = 3600

    private static var pending: Task<Void, Never>?

    static func follow(_ note: URL, in vault: Vault) {
        pending?.cancel()
        guard Editor.current == .obsidian else { return }
        pending = Task {
            try? await Task.sleep(for: settleTime)
            for _ in 0..<maxAttempts {
                guard await waitUntilObsidianIsInFront(), !Task.isCancelled else { return }
                switch vault.isShownInObsidian(note) {
                case true:
                    return
                case false:
                    Vault.showInObsidian(note)
                    try? await Task.sleep(for: settleTime)
                case nil:
                    // Cannot check: open it once and trust Obsidian.
                    Vault.showInObsidian(note)
                    return
                }
            }
            if !Task.isCancelled, vault.isShownInObsidian(note) == false {
                logger.error("Obsidian does not show the renamed note \(note.lastPathComponent, privacy: .private)")
            }
        }
    }

    /// Another note opened by Takku (a new Meeting, a click on a notification) wins.
    static func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// False if Obsidian quits, the wait is cancelled or lasts too long.
    private static func waitUntilObsidianIsInFront() async -> Bool {
        let deadline = Date().addingTimeInterval(maxWait)
        while !Task.isCancelled, Date() < deadline {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: Editor.obsidianBundleID).isEmpty else {
                return false
            }
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Editor.obsidianBundleID { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }
}
