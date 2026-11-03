import AppKit
import Observation
import Sparkle
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "updates")

/// Updates through Sparkle (ADR 0014). At launch and once a day, when the user leaves it on in
/// Settings, it reads the appcast published with the latest GitHub release; the request carries
/// nothing about the user or the Meetings. A newer version shows in the menu and in Settings →
/// About instead of a window popping up; choosing it opens Sparkle's window with what is new and
/// *Install Update*: Takku downloads the disk image, checks its EdDSA signature and Developer ID,
/// replaces itself and opens again. Never in the middle of a Meeting or its Processing: the
/// relaunch waits for them to end.
@MainActor
@Observable
final class UpdateChecker: NSObject {
    struct Release: Equatable {
        let version: String
    }

    /// A release newer than the running app, shown in the menu.
    private(set) var available: Release?

    /// True while a relaunch would interrupt a Meeting, its Processing or an import.
    @ObservationIgnored var isBusy: () -> Bool = { false }

    @ObservationIgnored private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    func start() {
        controller.updater.automaticallyChecksForUpdates = AppSettings.checkForUpdates
        controller.startUpdater()
    }

    /// From the switch in Settings.
    func setChecksAutomatically(_ isOn: Bool) {
        controller.updater.automaticallyChecksForUpdates = isOn
    }

    /// Sparkle's window: the new version with what changed and *Install Update*, or "You're up to date".
    func check() {
        // Takku has no Dock icon: without activating it the window would stay behind the others.
        NSApplication.shared.activate()
        controller.checkForUpdates(nil)
    }

    /// Runs `install` once nothing is recording or processing, checking every 30 seconds.
    private func relaunchWhenIdle(_ install: @escaping () -> Void) {
        Task {
            while isBusy() {
                try? await Task.sleep(for: .seconds(30))
            }
            logger.notice("Meeting over: installing the update")
            install()
        }
    }
}

extension UpdateChecker: SPUUpdaterDelegate {
    #if DEBUG
    /// `-testUpdateFeed URL` reads another appcast, to try an update with a local one.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "testUpdateFeed")
    }
    #endif

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        logger.notice("Takku \(version, privacy: .public) is available")
        MainActor.assumeIsolated { available = Release(version: version) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { available = nil }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        // Offline or rate-limited: nothing to show, tried again tomorrow.
        logger.notice("Update check failed: \(error.localizedDescription, privacy: .public)")
    }

    nonisolated func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        // Sparkle calls it on the main thread, and calls the handler there too.
        nonisolated(unsafe) let install = installHandler
        return MainActor.assumeIsolated {
            guard isBusy() else { return false }
            logger.notice("Update \(item.displayVersionString, privacy: .public) waits for the Meeting to end")
            relaunchWhenIdle { install() }
            return true
        }
    }
}

extension UpdateChecker: SPUStandardUserDriverDelegate {
    /// A daily check that finds a version adds it to the menu: no window opens by itself.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    /// Required with the gentle reminders: the menu already shows the version (`available`).
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {}
}
