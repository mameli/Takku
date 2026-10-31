import AVFoundation
import AppKit
import KeyboardShortcuts
import SwiftUI
import TakkuCore

/// The window shown at launch while no Vault is chosen (the first launch, in practice): a tour of
/// what Takku does, drawn on squared paper like takku.app, then the steps to do before the first
/// Meeting, so that no prompt or download interrupts the first call. Each step can be done later in
/// Settings; the menu reopens it with *Set up Takku…*.
struct WelcomeView: View {
    static let windowID = "welcome"
    static let size = CGSize(width: 760, height: 640)

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
    fileprivate static let isResuming: Bool = {
        let isResuming = (UserDefaults.standard.object(forKey: resumeUntilKey) as? Date).map { $0 > Date() } ?? false
        UserDefaults.standard.removeObject(forKey: resumeUntilKey)
        return isResuming
    }()

    /// Until when a relaunch opens this window again.
    private static let resumeUntilKey = "welcomeResumeUntil"

    fileprivate static func resumeAfterRelaunch() {
        UserDefaults.standard.set(Date().addingTimeInterval(10 * 60), forKey: resumeUntilKey)
    }

    let controller: MeetingController
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Back from a relaunch for Screen Recording: straight to the permissions.
    @State private var page: WelcomePage = Self.isResuming ? .permissions : .welcome
    @State private var isForward = true
    /// When the current page's scene started its loop.
    @State private var sceneStart = Date()
    @State private var permissions = PermissionsState()
    @State private var model = ModelState()

    var body: some View {
        WelcomeLayout(
            page: page, isForward: isForward,
            shortcuts: .current,
            modelProgress: model.isPreparing ? controller.modelMenuTitle : nil,
            go: go
        ) { page in
            if reduceMotion {
                WelcomeContent(page: page, t: page.still, shortcuts: .current)
            } else {
                TimelineView(.animation(paused: !page.isTour)) { context in
                    let elapsed = context.date.timeIntervalSince(sceneStart)
                    WelcomeContent(page: page, t: elapsed.truncatingRemainder(dividingBy: page.loop), shortcuts: .current)
                }
            }
        } setup: { page in
            switch page {
            case .permissions:
                PermissionsSetup(state: $permissions, isBusy: isBusy)
            case .summary:
                SummarySetup()
            default:
                TranscriptionSetup(
                    model: model,
                    isModelReady: controller.isModelReady,
                    progress: controller.modelMenuTitle,
                    retry: prepareModel
                )
            }
        } finish: {
            dismissWindow(id: Self.windowID)
        }
        // Takku has no Dock icon: without activating it the window would open behind the others.
        .onAppear { NSApplication.shared.activate() }
        .task {
            // Reopened from the background, System Settings in front: macOS may turn the activation down.
            guard Self.isResuming else { return }
            try? await Task.sleep(for: .milliseconds(500))
            await AudioPermissions.bringBack(NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(Self.windowID) == true })
        }
        // The model downloads while the tour plays, so it is ready when the tour gets to it.
        .task { if !controller.isModelReady { prepareModel() } }
        // A shortcut tried on the page that shows it plays its moment again.
        .onReceive(NotificationCenter.default.publisher(for: .markWithoutMeeting)) { _ in
            replay(at: MarkAndCaptureScene.markAt)
        }
        .onReceive(NotificationCenter.default.publisher(for: .screenshotWithoutMeeting)) { _ in
            replay(at: MarkAndCaptureScene.screenshotAt)
        }
        // Back from System Settings, where the microphone may have just been allowed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        // While Takku waits in the list: this process would not see the switch turned on.
        .task(id: permissions.screenRecording == .waiting) {
            while permissions.screenRecording == .waiting, !Task.isCancelled {
                if await ScreenshotTaker.isAllowedInNewProcess() {
                    permissions.screenRecording = .needsReopen
                    SettingsDragCard.shared.close()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onDisappear { SettingsDragCard.shared.close() }
    }

    private func go(to next: WelcomePage) {
        guard next != page else { return }
        isForward = next.rawValue > page.rawValue
        sceneStart = Date()
        withAnimation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.1)) { page = next }
    }

    private func replay(at moment: Double) {
        guard page == .markAndCapture else { return }
        sceneStart = Date().addingTimeInterval(-moment)
    }

    private func prepareModel() {
        guard !model.isPreparing else { return }
        Task {
            model.isPreparing = true
            model.error = nil
            do {
                try await controller.prepareTranscriptionModel()
            } catch {
                model.error = error.localizedDescription
            }
            model.isPreparing = false
        }
    }

    /// A relaunch now would interrupt a Meeting or its Processing.
    private var isBusy: Bool {
        controller.isInProgress || controller.processor.pendingCount > 0 || controller.importingFileName != nil
    }
}

extension Notification.Name {
    /// ⌃⌥⌘M or ⌃⌥⌘S pressed with no Meeting: the welcome window shows what they would do.
    static let markWithoutMeeting = Notification.Name("TakkuMarkWithoutMeeting")
    static let screenshotWithoutMeeting = Notification.Name("TakkuScreenshotWithoutMeeting")
}

extension WelcomeShortcuts {
    /// The shortcuts in use; a removed one shows its default.
    @MainActor static var current: Self {
        func label(_ name: KeyboardShortcuts.Name, _ fallback: String) -> String { name.shortcut?.description ?? fallback }
        return Self(
            startStop: label(.startStopMeeting, "⌃⌥⌘R"),
            mark: label(.markMoment, "⌃⌥⌘M"),
            screenshot: label(.takeScreenshot, "⌃⌥⌘S")
        )
    }
}

// MARK: - Pages

enum WelcomePage: Int, CaseIterable {
    case welcome, howItWorks, markAndCapture, speakers, beyondCalls, permissions, transcription, summary, ready

    /// The pages that show a scene; the others are steps to do.
    var isTour: Bool { self != .permissions && self != .transcription && self != .summary }

    var title: LocalizedStringKey {
        switch self {
        case .welcome: "Takku"
        case .howItWorks: "One shortcut, from any app"
        case .markAndCapture: "Mark a moment, keep a slide"
        case .speakers: "Who said what"
        case .beyondCalls: "Not only calls"
        case .permissions: "Before the first meeting"
        case .transcription: "Transcription"
        case .summary: "Who writes the Summary"
        case .ready: "All set"
        }
    }

    /// Only on the steps: on a tour page the caption under the scene says it all, so the eye
    /// follows one text at a time.
    var subtitle: LocalizedStringKey? {
        switch self {
        case .permissions: "Where the notes go, and what macOS asks once."
        case .transcription: "The model that transcribes your meetings, on this Mac."
        case .summary: "An AI model writes it: on your Mac, or an external one you choose."
        default: nil
        }
    }

    var loop: Double {
        switch self {
        case .welcome: HeroScene.loop
        case .howItWorks: HowItWorksScene.loop
        case .markAndCapture: MarkAndCaptureScene.loop
        case .speakers: SpeakersScene.loop
        case .beyondCalls: BeyondCallsScene.loop
        case .ready: ReadyScene.loop
        case .permissions, .transcription, .summary: 1
        }
    }

    /// The moment shown with Reduce Motion.
    var still: Double {
        switch self {
        case .welcome: HeroScene.still
        case .howItWorks: HowItWorksScene.still
        case .markAndCapture: MarkAndCaptureScene.still
        case .speakers: SpeakersScene.still
        case .beyondCalls: BeyondCallsScene.still
        case .ready: ReadyScene.still
        case .permissions, .transcription, .summary: 0
        }
    }
}

/// A tour page's scene and caption at `t`.
struct WelcomeContent: View {
    var page: WelcomePage
    var t: Double
    var shortcuts: WelcomeShortcuts

    var body: some View {
        VStack(spacing: 10) {
            Group {
                switch page {
                case .welcome: HeroScene(t: t)
                case .howItWorks: HowItWorksScene(t: t, shortcuts: shortcuts)
                case .markAndCapture: MarkAndCaptureScene(t: t, shortcuts: shortcuts)
                case .speakers: SpeakersScene(t: t)
                case .beyondCalls: BeyondCallsScene(t: t)
                case .ready, .permissions, .transcription, .summary: ReadyScene(t: t, shortcuts: shortcuts)
                }
            }
            .frame(width: WelcomeStage.size.width, height: WelcomeStage.size.height)
            .accessibilityHidden(true)
            // The shortcut the caption talks about, right above it: the eye stays in one place.
            Group {
                switch page {
                case .howItWorks: HowItWorksScene.keys(t, shortcuts: shortcuts)
                case .markAndCapture: MarkAndCaptureScene.keys(t, shortcuts: shortcuts)
                default: Color.clear
                }
            }
            .frame(height: 36)
            .accessibilityHidden(true)
            Caption(beats: beats, t: t, loop: page.loop)
                .font(Paper.serif(15))
                .foregroundStyle(Paper.text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560, minHeight: 44, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var beats: [Beat] {
        switch page {
        case .welcome: HeroScene.beats
        case .howItWorks: HowItWorksScene.beats(shortcuts)
        case .markAndCapture: MarkAndCaptureScene.beats(shortcuts)
        case .speakers: SpeakersScene.beats
        case .beyondCalls: BeyondCallsScene.beats
        case .ready, .permissions, .transcription, .summary: ReadyScene.beats(shortcuts)
        }
    }
}

/// The sheet: heading, the page's scene or step, page dots and buttons. `scene` draws a tour page,
/// `setup` a step.
struct WelcomeLayout<Scene: View, Setup: View>: View {
    var page: WelcomePage
    var isForward: Bool
    var shortcuts: WelcomeShortcuts
    /// What the model download is doing, while it runs.
    var modelProgress: String?
    var go: (WelcomePage) -> Void
    @ViewBuilder var scene: (WelcomePage) -> Scene
    @ViewBuilder var setup: (WelcomePage) -> Setup
    var finish: () -> Void

    private static var margin: CGFloat { 88 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PaperSheet(margin: Self.margin)
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 18) {
                        heading
                        if page.isTour {
                            scene(page)
                        } else {
                            setup(page).frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .id(page)
                    .transition(.asymmetric(
                        insertion: .offset(x: isForward ? 40 : -40).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
                .frame(maxHeight: .infinity, alignment: .top)
                footer
            }
            .padding(.leading, Self.margin + 24)
            .padding(.trailing, 28)
            .padding(.top, 34)
            .padding(.bottom, 20)
        }
        .frame(width: WelcomeView.size.width, height: WelcomeView.size.height)
        .background(Paper.sheet)
    }

    @ViewBuilder private var heading: some View {
        if page == .welcome {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                Text(verbatim: "Takku").font(Paper.hand(44, bold: true)).foregroundStyle(Paper.ink)
                    .accessibilityAddTraits(.isHeader)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(page.title).font(Paper.hand(30, bold: true)).foregroundStyle(Paper.ink)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle = page.subtitle {
                    Text(subtitle).font(Paper.serif(14)).foregroundStyle(Paper.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            HStack(spacing: 7) {
                ForEach(WelcomePage.allCases, id: \.self) { other in
                    Button { go(other) } label: {
                        Sketch(Circle(), seed: 600 &+ UInt64(other.rawValue))
                            .pencil(other == page ? Paper.pencil : .clear, outline: other == page ? Paper.pencil : Paper.graphite.opacity(0.6))
                            .frame(width: 10, height: 10)
                            .padding(3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(other.title))
                }
            }
            if let modelProgress, page != .transcription {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(verbatim: modelProgress).font(Paper.hand(12)).foregroundStyle(Paper.graphite).lineLimit(1)
                }
            }
            Spacer()
            if let previous = WelcomePage(rawValue: page.rawValue - 1) {
                Button("Back") { go(previous) }
                    .buttonStyle(PaperButtonStyle(isPrimary: false))
                    .keyboardShortcut(.leftArrow, modifiers: [])
            }
            if let next = WelcomePage(rawValue: page.rawValue + 1) {
                Button(page == .welcome ? "Get started" : "Continue") { go(next) }
                    .buttonStyle(PaperButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done", action: finish)
                    .buttonStyle(PaperButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(height: 40)
    }
}

// MARK: - Setup steps

/// The permissions as this window knows them; kept while the pages change.
struct PermissionsState {
    var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    /// Whether the last test heard the system audio; `nil` before one.
    var systemAudio: Bool?
    var isTestingSystemAudio = false
    var screenRecording = CGPreflightScreenCaptureAccess() ? ScreenRecording.on : .off
}

/// Screen Recording as this window knows it: allowed only from the launch after the switch is on.
enum ScreenRecording {
    case off
    /// System Settings is open with the card to drag Takku into the list.
    case waiting
    case needsReopen
    case on
}

/// The transcription model being downloaded and prepared from here.
struct ModelState {
    var isPreparing = false
    var error: String?
}

/// A step on the paper: done or not, what it is, and what to do.
private struct SetupRow<Actions: View>: View {
    var seed: UInt64
    var isDone: Bool?
    var title: LocalizedStringKey
    var detail: Text
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HandStatus(isDone: isDone).padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Paper.hand(18, bold: true)).foregroundStyle(Paper.ink)
                detail.font(Paper.serif(13)).foregroundStyle(Paper.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 14) { actions }
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(seed)
    }
}

/// The notes folder and the permissions macOS asks for once.
struct PermissionsSetup: View {
    @Binding var state: PermissionsState
    var isBusy: Bool
    @AppStorage(AppSettings.vaultPathKey) private var vaultPath = ""

    var body: some View {
        VStack(spacing: 12) {
            SetupRow(
                seed: 640,
                isDone: vaultPath.isEmpty ? nil : true,
                title: "Notes folder",
                detail: vaultPath.isEmpty
                    ? Text("One Markdown note per meeting, which any app opens. Obsidian too, if you use it: choose your vault.")
                    : Text(verbatim: (vaultPath as NSString).abbreviatingWithTildeInPath)
            ) {
                // A ready folder, for those with none in mind: nothing to decide, nothing to install.
                if vaultPath.isEmpty {
                    Button("Use Documents/Takku") { if Vault.useSuggested() == nil { _ = Vault.choose() } }
                        .buttonStyle(PaperButtonStyle())
                    Button("Choose…") { _ = Vault.choose() }
                        .buttonStyle(PaperButtonStyle(isPrimary: false))
                } else {
                    Button("Change…") { _ = Vault.choose() }
                        .buttonStyle(PaperButtonStyle(isPrimary: false))
                }
            }

            SetupRow(seed: 650, isDone: audioDone, title: "Microphone and system audio", detail: audioDetail) {
                // One button, for what is missing; the test runs by itself after it.
                if state.isTestingSystemAudio {
                    ProgressView().controlSize(.small)
                } else if state.microphone == .denied || state.microphone == .restricted {
                    Button("Open System Settings") { PrivacyPane.microphone.open() }
                        .buttonStyle(PaperButtonStyle())
                } else if state.systemAudio == false {
                    Button("Show in System Settings") {
                        Self.showDragCard(.screenRecording, list: String(localized: "System Audio Recording Only"))
                    }
                    .buttonStyle(PaperButtonStyle())
                } else if audioDone != true {
                    Button("Allow") { allowAudio() }
                        .buttonStyle(PaperButtonStyle())
                }
            }
            // Back from System Settings, where the system audio may have just been allowed.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                guard state.systemAudio == false, !state.isTestingSystemAudio else { return }
                Task { await testSystemAudio() }
            }

            SetupRow(seed: 660, isDone: state.screenRecording == .on ? true : nil, title: "Screenshots (optional)", detail: screenDetail) {
                switch state.screenRecording {
                case .off, .waiting:
                    Button("Allow…") {
                        state.screenRecording = .waiting
                        Self.showDragCard(.screenRecording, list: String(localized: "Screen & System Audio Recording"))
                    }
                    .buttonStyle(PaperButtonStyle(isPrimary: false))
                case .needsReopen:
                    Button("Reopen Takku") { Self.relaunch() }
                        .buttonStyle(PaperButtonStyle())
                        .disabled(isBusy)
                        .help(isBusy ? String(localized: "After the meeting and its Processing.") : "")
                case .on:
                    EmptyView()
                }
            }
        }
    }

    private var audioDone: Bool? {
        if state.microphone == .authorized && state.systemAudio == true { return true }
        if state.microphone == .denied || state.microphone == .restricted || state.systemAudio == false { return false }
        return nil
    }

    private var audioDetail: Text {
        if state.systemAudio == false {
            Text("Takku did not hear its test sound. If you chose Don't Allow, add Takku to System Audio Recording Only, then Test again.")
        } else if state.microphone == .denied || state.microphone == .restricted {
            Text("The microphone is not allowed: turn Takku on in System Settings.")
        } else {
            Text("Takku records your voice and the call. macOS asks once for each: choose Allow.")
        }
    }

    private var screenDetail: Text {
        switch state.screenRecording {
        case .waiting: Text("Turn Takku on in Screen & System Audio Recording: drag it there if it is not in the list.")
        case .needsReopen: Text("Allowed: macOS applies it once Takku reopens.")
        case .off: Text("For the screenshots during a meeting. macOS applies it once Takku reopens.")
        case .on: Text("Allowed: the screenshot shortcut works during a meeting.")
        }
    }

    private func allowAudio() {
        // Taken now: while the prompts are open another app is in front.
        let window = NSApplication.shared.keyWindow
        Task {
            await AudioPermissions.request()
            state.microphone = AVCaptureDevice.authorizationStatus(for: .audio)
            await AudioPermissions.bringBack(window)
            // Once the system audio prompt is answered, which can be after `request()`.
            await testSystemAudio()
        }
    }

    private func testSystemAudio() async {
        state.isTestingSystemAudio = true
        state.systemAudio = await AudioPermissions.hearsSystemAudio()
        state.isTestingSystemAudio = false
    }

    /// Opens `pane` with the card to drag Takku into `list`. Any switch turned on in that pane makes
    /// macOS offer Quit & Reopen: this window then comes back.
    private static func showDragCard(_ pane: PrivacyPane, list: String) {
        WelcomeView.resumeAfterRelaunch()
        SettingsDragCard.shared.show(for: pane, list: list)
    }

    /// Quits and opens Takku again once this process has exited: two Takku running at once would both record.
    private static func relaunch() {
        WelcomeView.resumeAfterRelaunch()
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [
            "-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundleURL.path(percentEncoded: false),
        ]
        guard (try? process.run()) != nil else { return }
        NSApplication.shared.terminate(nil)
    }
}

/// The transcription model and the optional switches.
struct TranscriptionSetup: View {
    var model: ModelState
    var isModelReady: Bool
    var progress: String?
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            let selected = TranscriptionModel.selected
            SetupRow(
                seed: 670,
                isDone: isModelReady ? true : model.error == nil ? nil : false,
                title: "Transcription model",
                detail: model.error.map { Text(verbatim: $0) }
                    ?? Text("\(selected.name), \(selected.downloadMB) MB, downloaded once and prepared for this Mac. It takes a few minutes: you can go on meanwhile.")
            ) {
                if model.isPreparing {
                    ProgressView().controlSize(.small)
                    if let progress { Text(verbatim: progress).font(Paper.hand(13)).foregroundStyle(Paper.graphite) }
                } else if !isModelReady {
                    Button(model.error == nil ? "Download and prepare" : "Try again", action: retry)
                        .buttonStyle(PaperButtonStyle())
                }
            }

            HStack(alignment: .top, spacing: 24) {
                LaunchAtLoginToggle()
                CalendarToggle()
            }
            .toggleStyle(.checkbox)
            .font(Paper.serif(13))
            .foregroundStyle(Paper.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
        }
    }
}

// MARK: - Render

#if DEBUG
/// `-renderWelcome DIR`: writes every page of the tour at a few moments, light and dark, as PNGs,
/// then quits before Takku starts (no menu bar item, no shortcuts).
enum WelcomeRender {
    static let argument = "-renderWelcome"

    @MainActor static func runIfRequested() {
        guard let index = CommandLine.arguments.firstIndex(of: argument), index + 1 < CommandLine.arguments.count else { return }
        let directory = URL(filePath: CommandLine.arguments[index + 1], directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for page in WelcomePage.allCases {
                let moments = page.isTour ? stride(from: 0.0, to: page.loop, by: page.loop / 6).map { $0 } + [page.still] : [0]
                for t in moments {
                    let view = WelcomeLayout(
                        page: page, isForward: true, shortcuts: WelcomeShortcuts(),
                        modelProgress: "Downloading transcription model… 34%", go: { _ in }
                    ) { page in
                        WelcomeContent(page: page, t: t, shortcuts: WelcomeShortcuts())
                    } setup: { page in
                        if page == .permissions {
                            PermissionsSetup(state: .constant(PermissionsState()), isBusy: false)
                        } else if page == .summary {
                            SummarySetup(previewPacks: [5, 10, 20].map { price in
                                TakkuCredit.Pack(priceEuros: Decimal(price), url: TakkuCredit.buyURL.appending(path: "\(price)"), isRecommended: price == 10)
                            })
                        } else {
                            TranscriptionSetup(model: ModelState(isPreparing: true), isModelReady: false, progress: "Downloading transcription model… 34%", retry: {})
                        }
                    } finish: {}
                    let renderer = ImageRenderer(content: view.environment(\.colorScheme, name == "dark" ? .dark : .light))
                    renderer.scale = 2
                    NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                        let file = String(format: "%@-%d-%@-%05.2f.png", name, page.rawValue, String(describing: page), t)
                        try? png.write(to: directory.appending(path: file))
                    }
                }
            }
        }
        exit(0)
    }
}
#endif
