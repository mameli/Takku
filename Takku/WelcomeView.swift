import AVFoundation
import AppKit
import KeyboardShortcuts
import SwiftUI

/// The window shown at launch while no Vault is chosen (the first launch, in practice): the steps
/// to do before the first Meeting, so that no prompt or download interrupts the first call.
/// Each step can be done later in Settings; the menu reopens it with *Set up Takku…*.
struct WelcomeView: View {
    static let windowID = "welcome"

    /// While there is no Vault, and once more when Takku reopens for Screen Recording from here;
    /// afterwards from the menu. In Debug builds `-showWelcome YES` shows it anyway, to try it with
    /// the real settings (*Choose…* saves the Vault for real). Read once per launch.
    static var isNeededAtLaunch: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "showWelcome") { return true }
        #endif
        return isResuming || AppSettings.vaultPath == nil
    }

    /// Takku was just reopened from here, by *Reopen Takku* or by macOS's *Quit & Reopen* after a
    /// switch in System Settings. Read once per launch.
    private static let isResuming: Bool = {
        let isResuming = (UserDefaults.standard.object(forKey: resumeUntilKey) as? Date).map { $0 > Date() } ?? false
        UserDefaults.standard.removeObject(forKey: resumeUntilKey)
        return isResuming
    }()

    /// Until when a relaunch opens this window again.
    private static let resumeUntilKey = "welcomeResumeUntil"

    private static func resumeAfterRelaunch() {
        UserDefaults.standard.set(Date().addingTimeInterval(10 * 60), forKey: resumeUntilKey)
    }

    /// Opens `pane` with the card to drag Takku into `list`. Any switch turned on in that pane makes
    /// macOS offer Quit & Reopen: this window then comes back.
    private static func showDragCard(_ pane: PrivacyPane, list: String) {
        resumeAfterRelaunch()
        SettingsDragCard.shared.show(for: pane, list: list)
    }

    /// Quits and opens Takku again once this process has exited: two Takku running at once would both record.
    private static func relaunch() {
        resumeAfterRelaunch()
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [
            "-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundleURL.path(percentEncoded: false),
        ]
        guard (try? process.run()) != nil else { return }
        NSApplication.shared.terminate(nil)
    }

    let controller: MeetingController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(AppSettings.vaultPathKey) private var vaultPath = ""
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var audioAsked = false
    /// Whether the last test heard the system audio; `nil` before one.
    @State private var systemAudio: Bool?
    @State private var isTestingSystemAudio = false
    @State private var screenRecording = CGPreflightScreenCaptureAccess() ? ScreenRecording.on : .off
    @State private var isPreparingModel = false
    @State private var modelError: String?

    var body: some View {
        Form {
            Section {
                Text("Takku records your meetings, transcribes them on this Mac and writes the notes into Obsidian. A few steps before the first one:")
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                AppIdentity().frame(maxWidth: .infinity).padding(.bottom, 8)
            }

            Section {
                Text("One note per meeting goes into its Meetings folder. Any folder works.")
                    .foregroundStyle(.secondary)
                LabeledContent("Folder") {
                    HStack {
                        Text(vaultPath.isEmpty ? String(localized: "None") : vaultPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(vaultPath.isEmpty ? .secondary : .primary)
                        Button("Choose…") { _ = Vault.choose() }
                    }
                }
            } header: {
                Step(number: 1, title: "Obsidian vault", isDone: !vaultPath.isEmpty)
            }

            Section {
                Text("Takku records your voice and the call. macOS asks once for each: choose Allow.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Allow microphone and system audio") {
                        // Taken now: while the prompts are open another app is in front.
                        let window = NSApplication.shared.keyWindow
                        Task {
                            await AudioPermissions.request()
                            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
                            audioAsked = true
                            await AudioPermissions.bringBack(window)
                            // Once the system audio prompt is answered, which can be after `request()`.
                            await testSystemAudio()
                        }
                    }
                    .disabled(audioAsked || (microphone == .authorized && systemAudio == true))
                    Spacer()
                }
                PermissionRow("Microphone", isAllowed: microphone == .notDetermined ? nil : microphone == .authorized) {
                    if microphone == .denied || microphone == .restricted {
                        Button("Open System Settings") { PrivacyPane.microphone.open() }
                    }
                }
                PermissionRow("System audio", isAllowed: systemAudio) {
                    if isTestingSystemAudio {
                        ProgressView().controlSize(.small)
                    } else {
                        if systemAudio == false {
                            Button("Show in System Settings") {
                                Self.showDragCard(.screenRecording, list: String(localized: "System Audio Recording Only"))
                            }
                        }
                        Button("Test") { Task { await testSystemAudio() } }
                            .help("Takku plays a short sound and checks that it hears it.")
                    }
                }
                if systemAudio == false {
                    Text("Takku did not hear its test sound. If you chose Don't Allow, add Takku to System Audio Recording Only, then Test again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PermissionRow("Screenshots (optional)", isAllowed: screenRecording == .on) {
                    switch screenRecording {
                    case .off, .waiting:
                        Button("Allow…") {
                            screenRecording = .waiting
                            Self.showDragCard(.screenRecording, list: String(localized: "Screen & System Audio Recording"))
                        }
                    case .needsReopen:
                        Button("Reopen Takku") { Self.relaunch() }
                            .disabled(isBusy)
                            .help(isBusy ? String(localized: "After the meeting and its Processing.") : "")
                    case .on:
                        EmptyView()
                    }
                }
                switch screenRecording {
                case .waiting:
                    Text("Turn Takku on in Screen & System Audio Recording: drag it there if it is not in the list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .needsReopen:
                    Text("Allowed: macOS applies it once Takku reopens.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .off, .on:
                    EmptyView()
                }
            } header: {
                Step(number: 2, title: "Permissions", isDone: microphone == .authorized && systemAudio == true)
            }

            Section {
                let model = TranscriptionModel.selected
                Text("\(model.name), \(model.downloadMB) MB, downloaded once and prepared for this Mac. It takes a few minutes: you can go on meanwhile.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Download and prepare") {
                        Task {
                            isPreparingModel = true
                            modelError = nil
                            do {
                                try await controller.prepareTranscriptionModel()
                            } catch {
                                modelError = error.localizedDescription
                            }
                            isPreparingModel = false
                        }
                    }
                    .disabled(isPreparingModel || controller.isModelReady)
                    if isPreparingModel {
                        ProgressView().controlSize(.small)
                        if let title = controller.modelMenuTitle { Text(verbatim: title).foregroundStyle(.secondary) }
                    }
                    Spacer()
                }
                if let modelError {
                    Text(modelError).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } header: {
                Step(number: 3, title: "Transcription model", isDone: controller.isModelReady)
            }

            Section {
                Text("Until you choose a Summary Profile, Takku writes only the Transcript. The simplest is Takku Credit: prepaid credit, with nothing to set up but the key that arrives by email. Settings also has Ollama, a model on this Mac, and Mistral, TensorX and OpenRouter, which only need your API key. Any other OpenAI-compatible provider you trust works too.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Choose a Profile in Settings…") {
                        SettingsRequest.shared.showsProfiles = true
                        NSApplication.shared.activate()
                        openSettings()
                    }
                    Link("Examples", destination: URL(string: "https://takku.app/setup#first-setup")!)
                    Spacer()
                }
            } header: {
                Step(number: 4, title: "Summary (optional)", isDone: AppSettings.activeProviderProfile != nil)
            }

            Section("Optional") {
                LaunchAtLoginToggle()
                CalendarToggle()
            }

            Section {
                HStack(alignment: .center) {
                    Image("MenuBarIcon").renderingMode(.template)
                    Group {
                        if let label = KeyboardShortcuts.Name.startStopMeeting.shortcut?.description {
                            Text("Takku lives in the menu bar: start a meeting from there or with \(label).")
                        } else {
                            Text("Takku lives in the menu bar: start a meeting from there.")
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Done") { dismissWindow(id: Self.windowID) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 720)
        // Takku has no Dock icon: without activating it the window would open behind the others.
        .onAppear { NSApplication.shared.activate() }
        .task {
            // Reopened from the background, System Settings in front: macOS may turn the activation down.
            guard Self.isResuming else { return }
            try? await Task.sleep(for: .milliseconds(500))
            await AudioPermissions.bringBack(NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(Self.windowID) == true })
        }
        // Back from System Settings, where the microphone may have just been allowed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        // While Takku waits in the list: this process would not see the switch turned on.
        .task(id: screenRecording == .waiting) {
            while screenRecording == .waiting, !Task.isCancelled {
                if await ScreenshotTaker.isAllowedInNewProcess() {
                    screenRecording = .needsReopen
                    SettingsDragCard.shared.close()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onDisappear { SettingsDragCard.shared.close() }
    }

    private func testSystemAudio() async {
        isTestingSystemAudio = true
        systemAudio = await AudioPermissions.hearsSystemAudio()
        isTestingSystemAudio = false
    }

    /// A relaunch now would interrupt a Meeting or its Processing.
    private var isBusy: Bool {
        controller.isInProgress || controller.processor.pendingCount > 0 || controller.importingFileName != nil
    }
}

/// Screen Recording as this window knows it: allowed only from the launch after the switch is on.
private enum ScreenRecording {
    case off
    /// System Settings is open with the card to drag Takku into the list.
    case waiting
    case needsReopen
    case on
}

/// A permission and its state: allowed, not allowed, or `nil` when macOS does not say.
private struct PermissionRow<Actions: View>: View {
    let title: LocalizedStringKey
    let isAllowed: Bool?
    @ViewBuilder let actions: Actions

    init(_ title: LocalizedStringKey, isAllowed: Bool?, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.isAllowed = isAllowed
        self.actions = actions()
    }

    var body: some View {
        LabeledContent {
            HStack { actions }
        } label: {
            Label {
                Text(title)
            } icon: {
                switch isAllowed {
                case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case false?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case nil: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct Step: View {
    let number: Int
    let title: LocalizedStringKey
    let isDone: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(isDone ? Color.green : Color.secondary)
            Text(title)
        }
    }
}
