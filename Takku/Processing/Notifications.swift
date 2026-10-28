import AppKit
import os
@preconcurrency import UserNotifications

private let logger = Logger(subsystem: "app.takku.takku", category: "notifications")

/// Takku's notifications. Clicking "Summary ready" opens the note in the Editor; the call
/// suggestions have a button that starts or stops the Meeting.
@MainActor
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    /// What a notification offers to do, beyond opening its note.
    enum Action: String {
        case startMeeting
        case stopMeeting
    }

    static let shared = Notifications()
    private nonisolated static let noteKey = "notePath"
    /// Called when the user chooses a notification's action; set by `MeetingController`.
    var onAction: (Action) -> Void = { _ in }

    /// Asks for permission once, at app launch.
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Action.startMeeting.rawValue,
                actions: [UNNotificationAction(identifier: Action.startMeeting.rawValue, title: String(localized: "Start meeting"))],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Action.stopMeeting.rawValue,
                actions: [UNNotificationAction(identifier: Action.stopMeeting.rawValue, title: String(localized: "Stop meeting"))],
                intentIdentifiers: []
            ),
        ])
        Task {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                logger.info("Notification permission requested: granted \(granted, privacy: .public)")
            } catch {
                logger.error("Notification permission request failed: \(error, privacy: .public)")
            }
        }
    }

    /// The permission is read at every notification, not once at launch: it can be turned on in
    /// System Settings while Takku is running.
    /// `action`: the button the notification shows.
    func notify(title: String, body: String, note: URL?, action: Action? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let note { content.userInfo = [Self.noteKey: note.path(percentEncoded: false)] }
        if let action { content.categoryIdentifier = action.rawValue }
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else {
                logger.notice("Notification \"\(title, privacy: .public)\" not shown: permission status \(status.rawValue, privacy: .public)")
                return
            }
            do {
                try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            } catch {
                logger.error("Notification \"\(title, privacy: .public)\" not delivered: \(error, privacy: .public)")
            }
        }
    }

    /// The outcome of a Processing: "Summary ready" or "Transcript ready" (with the warnings, if
    /// any) opening the note, or "Processing failed" with the reason.
    func processingFinished(
        noteName: String, note: URL?, hasVault: Bool, hasSummary: Bool, problems: [String], warnings: [String]
    ) {
        if !problems.isEmpty {
            notify(title: String(localized: "Processing failed"), body: "\(noteName): \(problems.joined(separator: " "))", note: note)
        } else if !hasVault {
            notify(title: String(localized: "Transcript ready"), body: String(localized: "Set up the Vault to get the Summary."), note: note)
        } else {
            let body = warnings.isEmpty ? noteName : "\(noteName) (\(warnings.joined(separator: " ")))"
            notify(title: hasSummary ? String(localized: "Summary ready") : String(localized: "Transcript ready"), body: body, note: note)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        // The button, or a click on "Looks like a call" itself: stopping takes the button.
        let action = Action(rawValue: response.actionIdentifier)
            ?? (response.actionIdentifier == UNNotificationDefaultActionIdentifier
                && content.categoryIdentifier == Action.startMeeting.rawValue ? .startMeeting : nil)
        let path = content.userInfo[Self.noteKey] as? String
        await MainActor.run {
            if let action {
                onAction(action)
            } else if let path {
                let url = URL(filePath: path)
                if let vault = Vault.configured, vault.contains(url) {
                    Vault.openInEditor(url)
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// Takku has no window in the foreground: without this, notifications would never show.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
