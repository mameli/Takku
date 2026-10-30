import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// Icon, name and version at the top of Settings.
struct AppIdentity: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 4) {
            // From the asset catalog: the icon macOS caches for the app can be an old one.
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text(verbatim: "Takku").font(.title2.bold()).foregroundStyle(.primary)
            Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }
}

/// Starts Takku when the user logs in, as a login item registered with macOS: it also appears,
/// and can be turned off, in System Settings → General → Login Items.
struct LaunchAtLoginToggle: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Toggle("Open at login", isOn: Binding(
            get: { status == .enabled || status == .requiresApproval },
            // A closure, not `setEnabled` itself: Swift 6.3 (Xcode 26) crashes converting the method.
            set: { setEnabled($0) }
        ))
        // The status can change in System Settings while this window is closed.
        .onAppear { status = SMAppService.mainApp.status }
        if status == .requiresApproval {
            HStack {
                Text("Allow Takku in System Settings → Login Items.").foregroundStyle(.secondary)
                Spacer()
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        if let error {
            Text(error).foregroundStyle(.secondary)
        }
    }

    private func setEnabled(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        status = SMAppService.mainApp.status
    }
}

/// The daily question to GitHub about a newer release.
struct UpdatesToggle: View {
    @AppStorage(AppSettings.checkForUpdatesKey) private var checkForUpdates = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Check for updates", isOn: $checkForUpdates)
            Text("Once a day Takku asks GitHub for the latest version; nothing about you or your Meetings is sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Notifications that suggest starting and stopping a Meeting when a call app takes and releases the microphone.
struct SuggestCallsToggle: View {
    @AppStorage(AppSettings.suggestCallsKey) private var suggestCalls = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Suggest recording when a call starts", isOn: $suggestCalls)
            Text("A notification when an app uses the microphone for a while, and another when it stops. Takku never starts or stops by itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Names the Meeting note after the calendar event in progress and lists its participants.
/// Turning it on asks macOS for access to the calendars. Without access the switch shows off but
/// the choice is kept: a build with another signature (a local one, same bundle id) has no access
/// and must not turn it off for the installed Takku, which shares its settings.
struct CalendarToggle: View {
    @AppStorage(AppSettings.useCalendarKey) private var useCalendar = false
    @State private var isAuthorized = MeetingCalendar.isAuthorized
    @State private var isDenied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Use the calendar", isOn: Binding(get: { useCalendar && isAuthorized }, set: { setEnabled($0) }))
            Text("The Meeting note takes the name and the participants of the event in progress.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Access can be revoked in System Settings while Takku is running.
        .onAppear { isAuthorized = MeetingCalendar.isAuthorized }
        if isDenied {
            HStack {
                Text("Allow Takku in System Settings → Privacy & Security → Calendars.").foregroundStyle(.secondary)
                Spacer()
                Button("Open Calendars") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            }
        }
    }

    private func setEnabled(_ isEnabled: Bool) {
        guard isEnabled else {
            useCalendar = false
            return
        }
        Task {
            let granted = await MeetingCalendar.requestAccess()
            if granted { useCalendar = true }
            isAuthorized = granted
            isDenied = !granted
        }
    }
}

/// The global keyboard shortcuts, each one changed or removed by the user.
struct ShortcutsSection: View {
    var body: some View {
        Section("Keyboard shortcuts") {
            ShortcutRow("Start or stop a meeting", name: .startStopMeeting)
            ShortcutRow("Mark this moment", name: .markMoment)
            ShortcutRow("Take a screenshot", name: .takeScreenshot)
        }
    }
}

private struct ShortcutRow: View {
    private let title: LocalizedStringKey
    private let name: KeyboardShortcuts.Name

    init(_ title: LocalizedStringKey, name: KeyboardShortcuts.Name) {
        self.title = title
        self.name = name
    }

    var body: some View {
        KeyboardShortcuts.Recorder(title, name: name)
            .shortcutValidation(validate)
    }

    /// Two of Takku's shortcuts on the same keys would both run.
    private func validate(_ shortcut: KeyboardShortcuts.Shortcut) -> KeyboardShortcuts.ValidationResult {
        guard KeyboardShortcuts.Name.takku.contains(where: { $0 != name && $0.shortcut == shortcut }) else { return .allow }
        return .disallow(reason: String(localized: "Another of Takku's shortcuts already uses these keys."))
    }
}
