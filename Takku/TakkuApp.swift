import AppKit
import SwiftUI
import TakkuCore

@main
struct TakkuApp: App {
    @State private var controller: MeetingController

    init() {
        _controller = State(initialValue: MeetingController())
        DockPresence.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MeetingMenu(controller: controller)
        } label: {
            MenuBarLabel(controller: controller)
                #if DEBUG
                .task { await controller.runSmokeTestIfRequested() }
                #endif
        }

        Settings {
            SettingsView(models: controller.models)
        }

        Window("Welcome to Takku", id: WelcomeView.windowID) {
            WelcomeView(controller: controller)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(WelcomeView.isNeededAtLaunch ? .presented : .suppressed)
    }
}

private struct MenuBarLabel: View {
    let controller: MeetingController

    // While recording only the red dot: narrow, so it does not end up behind the notch.
    // The duration is in the menu.
    var body: some View {
        if controller.isShowingScreenshot {
            Image(nsImage: .screenshotIndicator)
        } else if controller.isShowingMark {
            Image(nsImage: .markIndicator)
        } else if controller.isInProgress {
            Image(nsImage: .recordingIndicator)
        } else if controller.processor.pendingCount > 0 || controller.importingFileName != nil {
            Image(systemName: "hourglass")
        } else {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .accessibilityLabel(Text(verbatim: "Takku"))
        }
    }
}

private struct MeetingMenu: View {
    let controller: MeetingController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppSettings.activeProviderProfileKey) private var activeProfileID = ""
    @AppStorage(AppSettings.vaultPathKey) private var vaultPath = ""

    var body: some View {
        if controller.isInProgress {
            Text(verbatim: controller.recordingMenuTitle ?? "")
            ForEach(controller.silenceWarnings, id: \.self) { Text(verbatim: $0) }
            // The shortcut is global (GlobalHotKey): shown here as a reminder only, not as a menu key.
            Button("Stop meeting    ⌃⌥⌘R") { controller.stop() }
            Button("Mark this moment    ⌃⌥⌘M") { controller.mark() }
            Button("Take a screenshot    ⌃⌥⌘S") {
                // Once the menu has closed, so it is not in the image.
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    controller.takeScreenshot()
                }
            }
            if !controller.marks.isEmpty {
                Text("Marked moments: \(controller.marks.count)")
            }
            if controller.screenshotCount > 0 {
                Text("Screenshots: \(controller.screenshotCount)")
            }
            if !controller.isMarkHotKeyAvailable {
                Text("⌃⌥⌘M is already used by another app")
            }
            if !controller.isScreenshotHotKeyAvailable {
                Text("⌃⌥⌘S is already used by another app")
            }
            if !controller.calendarEvents.isEmpty {
                CalendarEventMenu(controller: controller)
            }
        } else {
            Button("Start meeting    ⌃⌥⌘R") { Task { await controller.start() } }
            if controller.importingFileName == nil {
                Button("Import audio…") { controller.chooseAudioToImport() }
            }
        }
        if let importingFileName = controller.importingFileName {
            Text("Importing \(importingFileName)…")
        }
        if !controller.isHotKeyAvailable {
            Text("⌃⌥⌘R is already used by another app")
        }

        // With the "Transcript" Profile there is no Summary, so no Template to choose.
        if !activeProfileID.isEmpty {
            Picker("Template", selection: Bindable(controller).templateName) {
                ForEach(TakkuFolder.templateChoices(including: controller.templateName), id: \.self) { Text($0).tag($0) }
            }
        }
        // A Meeting's Profile is fixed at the start: changing it while recording would have no effect.
        if !controller.isInProgress {
            ProviderProfileMenu()
        }

        if let modelMenuTitle = controller.modelMenuTitle {
            Divider()
            Text(verbatim: modelMenuTitle)
        }
        if controller.processor.pendingCount > 0 {
            Divider()
            if controller.processor.pendingCount == 1 {
                Text("Processing…")
            } else {
                Text("Processing… (\(controller.processor.pendingCount - 1) more queued)")
            }
        }

        if let lastError = controller.lastError {
            Divider()
            Text("⚠️ \(lastError)")
        }

        if !controller.processor.recent.isEmpty {
            Divider()
            RecentMeetingsMenu(controller: controller)
        }

        #if DEBUG
        if let directory = controller.lastRecordingDirectory, !controller.isInProgress {
            Button("Show last Recording in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            }
        }
        if controller.processor.lastTranscriptURL != nil {
            Button("Open last Transcript") { controller.processor.openLastTranscript() }
        }
        #endif

        if controller.microphoneDenied {
            Divider()
            Button("Microphone not authorized: open System Settings…") {
                controller.openMicrophoneSettings()
            }
        }
        if controller.screenshotNotAllowed {
            Divider()
            Button("Screenshot not taken: allow Screen Recording in System Settings…") {
                controller.openScreenRecordingSettings()
            }
        }

        if let release = controller.updates.available {
            Divider()
            Button("Takku \(release.version) is available…") { controller.updates.openReleasePage() }
        }

        Divider()
        if vaultPath.isEmpty {
            Button("Set up Takku…") {
                NSApplication.shared.activate()
                openWindow(id: WelcomeView.windowID)
            }
        }
        Button("Report a problem…") { ProblemReporter.report() }
        Button("Settings…") {
            // Takku has no Dock icon: without activating it the window would stay behind the others.
            NSApplication.shared.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        if !controller.isInProgress {
            Button("Quit Takku") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

/// The calendar event the Meeting in progress is for: Takku's guess, or another event in progress
/// at the start (the next call, one at the same time), or none.
private struct CalendarEventMenu: View {
    let controller: MeetingController

    var body: some View {
        Picker("Calendar event", selection: Binding(
            get: { controller.calendarEvent },
            set: { controller.chooseCalendarEvent($0) }
        )) {
            ForEach(controller.calendarEvents, id: \.self) { event in
                Text(verbatim: label(event)).tag(Optional(event))
            }
            Text("None").tag(CalendarEvent?.none)
        }
    }

    /// "Weekly sync · 12:00–12:30": the time tells back-to-back events apart.
    private func label(_ event: CalendarEvent) -> String {
        let title = event.title.isEmpty ? String(localized: "Untitled event") : event.title
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(title) · \(start)–\(end)"
    }
}

/// The last five Meetings: open the note, Retry.
private struct RecentMeetingsMenu: View {
    let controller: MeetingController
    /// The *Show all* item names the Editor chosen in Settings.
    @AppStorage(AppSettings.editorKey) private var editor = ""

    var body: some View {
        Menu("Recent meetings") {
            ForEach(controller.processor.recent) { meeting in
                Menu(label(meeting)) {
                    Button("Open note") { controller.processor.openNote(meeting.id) }
                    // Only for a concluded Meeting: one being recorded or queued is left alone.
                    // It uses the Summary Profile chosen in this menu, and its Template too unless the
                    // Meeting failed: then it keeps its own.
                    if meeting.status.canRetry {
                        Button("Retry") {
                            controller.processor.retry(
                                meeting.id, templateName: controller.templateName,
                                profile: AppSettings.activeProviderProfile
                            )
                        }
                    }
                }
            }
            if let vault = Vault.configured {
                Divider()
                let showAll = Vault.ShowAll(Editor.resolved(chosen: editor))
                Button(showAll.title) { vault.show(showAll) }
            }
        }
    }

    private func label(_ meeting: MeetingProcessor.RecentMeeting) -> String {
        switch meeting.status {
        case .recording: "⏺ \(meeting.title)"
        case .queued, .processing, .regenerating: "⏳ \(meeting.title)"
        case .completed: meeting.title
        case .failed: "⚠️ \(meeting.title)"
        }
    }
}

private extension NSImage {
    /// Red dot: menu bar images are monochrome unless `isTemplate` is turned off.
    static let recordingIndicator: NSImage = {
        let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: String(localized: "Meeting in progress"))!
            .withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))!
        image.isTemplate = false
        return image
    }()

    /// Shown for a second after a Mark, in the same red as the recording dot.
    static let markIndicator: NSImage = {
        let image = NSImage(systemSymbolName: "star.circle.fill", accessibilityDescription: String(localized: "Moment marked"))!
            .withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))!
        image.isTemplate = false
        return image
    }()

    /// Shown for a second after a Screenshot, like the star after a Mark.
    static let screenshotIndicator: NSImage = {
        let image = NSImage(systemSymbolName: "camera.circle.fill", accessibilityDescription: String(localized: "Screenshot taken"))!
            .withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))!
        image.isTemplate = false
        return image
    }()
}

/// Quick switch of the Summary Profile (e.g. from a test one to an EU one).
private struct ProviderProfileMenu: View {
    @AppStorage(AppSettings.activeProviderProfileKey) private var activeID = ""
    /// Observed, not read once: Profiles added, renamed or deleted in Settings show up at once.
    @AppStorage(AppSettings.summaryProfilesKey) private var profilesData: Data?

    var body: some View {
        Picker("Summary Profile", selection: $activeID) {
            Text("Transcript").tag("")
            ForEach(AppSettings.decodeProfiles(profilesData)) { Text($0.displayName).tag($0.id.uuidString) }
        }
    }
}
