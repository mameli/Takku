import AppKit
import SwiftUI

/// The window shown at launch while no Vault is chosen (the first launch, in practice): the steps
/// to do before the first Meeting, so that no prompt or download interrupts the first call.
/// Each step can be done later in Settings; the menu reopens it with *Set up Takku…*.
struct WelcomeView: View {
    static let windowID = "welcome"

    /// While there is no Vault; afterwards from the menu. In Debug builds `-showWelcome YES` shows
    /// it anyway, to try it with the real settings (*Choose…* saves the Vault for real).
    static var isNeededAtLaunch: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "showWelcome") { return true }
        #endif
        return AppSettings.vaultPath == nil
    }

    let controller: MeetingController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(AppSettings.vaultPathKey) private var vaultPath = ""
    @State private var microphoneAllowed = AudioPermissions.microphoneAllowed
    @State private var permissionsAsked = false
    /// True only from the launch after it was allowed: macOS applies it when Takku is reopened.
    @State private var screenRecordingAllowed = CGPreflightScreenCaptureAccess()
    @State private var screenRecordingAsked = false
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
                            microphoneAllowed = AudioPermissions.microphoneAllowed
                            permissionsAsked = true
                            await AudioPermissions.bringBack(window)
                        }
                    }
                    .disabled(permissionsAsked)
                    Spacer()
                }
                if permissionsAsked && !microphoneAllowed {
                    HStack {
                        Text("The microphone is not allowed.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Open System Settings") { controller.openMicrophoneSettings() }
                    }
                }
                if permissionsAsked {
                    HStack {
                        Text("If you chose Don't Allow for the system audio, turn Takku on in Screen & System Audio Recording.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Open System Settings") { AudioPermissions.openSystemAudioSettings() }
                    }
                }
            } header: {
                Step(number: 2, title: "Microphone and system audio", isDone: permissionsAsked && microphoneAllowed)
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
                Text("Until you choose a Summary Profile, Takku writes only the Transcript. Settings has four ready: Ollama, a model on this Mac, then Mistral, TensorX and OpenRouter, which only need your API key. Any other OpenAI-compatible provider you trust works too.")
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

            // Last: the "Quit & Reopen" macOS offers would close this window, and with a Vault it does not come back.
            Section {
                Text("Only for screenshots during a meeting (⌃⌥⌘S). If macOS offers to reopen Takku, choose Later: the permission works from the next launch.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Allow screen recording") {
                        screenRecordingAllowed = ScreenshotTaker.isAllowed()
                        screenRecordingAsked = true
                    }
                    .disabled(screenRecordingAsked || screenRecordingAllowed)
                    Spacer()
                }
                if screenRecordingAsked && !screenRecordingAllowed {
                    HStack {
                        Text("Turn Takku on in Screen & System Audio Recording.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Open System Settings") { controller.openScreenRecordingSettings() }
                    }
                }
            } header: {
                Step(number: 5, title: "Screenshots (optional)", isDone: screenRecordingAllowed)
            }

            Section("Optional") {
                LaunchAtLoginToggle()
                CalendarToggle()
            }

            Section {
                HStack(alignment: .center) {
                    Image("MenuBarIcon").renderingMode(.template)
                    Text("Takku lives in the menu bar: start a meeting from there or with ⌃⌥⌘R.")
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
        // Back from System Settings, where the microphone may have just been allowed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            microphoneAllowed = AudioPermissions.microphoneAllowed
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
