import AppKit
import os
import TakkuCore
@preconcurrency import UserNotifications

private let logger = Logger(subsystem: "app.takku.takku", category: "notifications")

/// Takku's notifications. Clicking "Summary ready" opens the note in the Editor; the call
/// suggestions have a button that starts or stops the Meeting. The end of a Processing offers what
/// comes next when it applies: *Name speakers…* when some have no name, *Regenerate Summary* when
/// it failed with the Transcript written; buried in *Recent meetings*, they went unnoticed.
@MainActor
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    /// What a notification offers to do, beyond opening its note.
    enum Action: String, CaseIterable {
        case startMeeting
        case stopMeeting
        case nameSpeakers
        case regenerateSummary

        var title: String {
            switch self {
            case .startMeeting: String(localized: "Start meeting")
            case .stopMeeting: String(localized: "Stop meeting")
            case .nameSpeakers: String(localized: "Name speakers…")
            case .regenerateSummary: String(localized: "Regenerate Summary")
            }
        }
    }

    static let shared = Notifications()
    private nonisolated static let noteKey = "notePath"
    private nonisolated static let meetingKey = "takkuID"
    /// Called when the user chooses a notification's action, with the Meeting it is about if any;
    /// set by `MeetingController`.
    var onAction: (Action, UUID?) -> Void = { _, _ in }

    /// Sets up the delegate and the buttons. The permission is not asked here: the welcome window
    /// asks for it next to the other permissions, and Settings while it was never asked.
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Set(Action.allCases.map { action in
            UNNotificationCategory(
                identifier: action.rawValue,
                actions: [UNNotificationAction(identifier: action.rawValue, title: action.title, options: .foreground)],
                intentIdentifiers: []
            )
        }))
        Task {
            let registered = await center.notificationCategories().map(\.identifier).sorted()
            logger.notice("Notification categories registered: \(registered.joined(separator: ", "), privacy: .public)")
        }
    }

    /// Read each time it is shown: it changes in System Settings while Takku is running.
    static func access() async -> NotificationAccess {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return NotificationAccess(
            isDetermined: settings.authorizationStatus != .notDetermined,
            isAuthorized: [.authorized, .provisional].contains(settings.authorizationStatus),
            showsAlerts: settings.alertStyle != .none
        )
    }

    /// Shows macOS's prompt when it was never answered; afterwards macOS shows nothing, and only
    /// System Settings can change the answer.
    static func requestAccess() async -> NotificationAccess {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            logger.info("Notification permission requested: granted \(granted, privacy: .public)")
        } catch {
            logger.error("Notification permission request failed: \(error.logCode, privacy: .public) \(error, privacy: .private)")
        }
        return await access()
    }

    /// System Settings → Notifications, at Takku's own page.
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "app.takku.takku"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!)
    }

    /// The permission is read at every notification, not once at launch: it can be turned on in
    /// System Settings while Takku is running.
    /// `action`: the button the notification shows; `meeting`: the Meeting it acts on.
    func notify(title: String, body: String, note: URL?, action: Action? = nil, meeting: UUID? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        var info: [String: String] = [:]
        if let note { info[Self.noteKey] = note.path(percentEncoded: false) }
        if let meeting { info[Self.meetingKey] = meeting.uuidString }
        content.userInfo = info
        if let action { content.categoryIdentifier = action.rawValue }
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else {
                logger.notice("Notification \"\(title, privacy: .private)\" not shown: permission status \(status.rawValue, privacy: .public)")
                return
            }
            do {
                try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                logger.notice("Notification delivered with category \(content.categoryIdentifier.isEmpty ? "none" : content.categoryIdentifier, privacy: .public)")
            } catch {
                logger.error("Notification \"\(title, privacy: .private)\" not delivered: \(error.logCode, privacy: .public) \(error, privacy: .private)")
            }
        }
    }

    /// The outcome of a Processing: "Summary ready" or "Transcript ready" (with the warnings, if
    /// any) opening the note, or "Processing failed" with the reason. `rebuild` says how a
    /// Reprocess rebuilt the Transcript, on its own line. `unnamedSpeakers`: how many Speakers of
    /// the Transcript have no name, offered *Name speakers…*; `canRegenerate`: a failure with the
    /// Transcript in the Vault, offered *Regenerate Summary*.
    func processingFinished(
        meeting: UUID, noteName: String, note: URL?, hasVault: Bool, hasSummary: Bool, problems: [String], warnings: [String],
        rebuild: String? = nil, unnamedSpeakers: Int = 0, canRegenerate: Bool = false
    ) {
        let rebuildLine = rebuild.map { "\n\($0)" } ?? ""
        if !problems.isEmpty {
            notify(
                title: String(localized: "Processing failed"), body: "\(noteName): \(problems.joined(separator: " "))", note: note,
                action: canRegenerate ? .regenerateSummary : nil, meeting: meeting
            )
        } else if !hasVault {
            let detail = warnings.isEmpty ? String(localized: "Choose a notes folder to get the Summary.") : warnings.joined(separator: " ")
            notify(title: String(localized: "Transcript ready"), body: "\(noteName): \(detail)\(rebuildLine)", note: note)
        } else {
            let body = warnings.isEmpty ? noteName : "\(noteName) (\(warnings.joined(separator: " ")))"
            let speakersLine = unnamedSpeakers > 0 ? "\n" + String(localized: "Speakers without a name: \(unnamedSpeakers)") : ""
            notify(
                title: hasSummary ? String(localized: "Summary ready") : String(localized: "Transcript ready"),
                body: body + rebuildLine + speakersLine, note: note,
                action: unnamedSpeakers > 0 ? .nameSpeakers : nil, meeting: meeting
            )
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
        let meeting = (content.userInfo[Self.meetingKey] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run {
            if let action {
                onAction(action, meeting)
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
