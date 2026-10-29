import AVFoundation
import AppKit
import Carbon.HIToolbox
import Observation
import TakkuCore
import os

private let logger = Logger(subsystem: "app.takku.takku", category: "meeting")

/// Starting and stopping the Meeting: permissions, recording, Meeting note, global shortcut.
/// At the stop the Meeting goes to `MeetingProcessor`, which processes it.
@MainActor
@Observable
final class MeetingController {
    /// When the Meeting in progress started; `nil` when idle.
    private var startedAt: Date?
    private let recorder = MeetingRecorder()
    let models = TranscriptionModels()
    private let transcriber: LocalTranscriber
    private let diarizer = SpeakerDiarizer()
    let processor: MeetingProcessor
    private var currentTakkuID: UUID?
    private var now = Date()
    private var isRequestingPermission = false
    private var ticker: Task<Void, Never>?
    /// Menus being tracked. While the menu is open the timer does not touch observed state,
    /// otherwise every tick rebuilds its items (open submenus blink, the highlighted item loses
    /// its colour): it changes the title of the timer item in place instead.
    @ObservationIgnored private var openMenus = 0
    @ObservationIgnored private weak var openMenu: NSMenu?
    private var hotKey: GlobalHotKey?
    private let callDetector = CallDetector()
    let updates = UpdateChecker()
    private var markHotKey: GlobalHotKey?
    private var screenshotHotKey: GlobalHotKey?
    /// False if another app already uses ⌃⌥⌘R.
    var isHotKeyAvailable: Bool { hotKey?.isRegistered ?? false }
    /// False if another app already uses ⌃⌥⌘M.
    var isMarkHotKeyAvailable: Bool { markHotKey?.isRegistered ?? false }
    /// False if another app already uses ⌃⌥⌘S.
    var isScreenshotHotKeyAvailable: Bool { screenshotHotKey?.isRegistered ?? false }
    /// The Recording folder of the Meeting in progress, where its Marks and Screenshots are saved.
    private var currentDirectory: URL?
    /// Captures that Processing must await so a Screenshot taken just before Stop is not lost.
    @ObservationIgnored private var pendingScreenshots: [UUID: [Task<Void, Never>]] = [:]
    /// The Meeting note of the Meeting in progress, where Takku created it; `nil` if it was not created.
    private var currentNoteURL: URL?
    /// The calendar events the Meeting in progress can be for, the likeliest first: the menu
    /// offers them when the guess is wrong (back-to-back or overlapping calls).
    private(set) var calendarEvents: [CalendarEvent] = []
    /// The event the note is named after, `nil` for none.
    private(set) var calendarEvent: CalendarEvent?
    /// The Marks of the Meeting in progress, in seconds from its start.
    private(set) var marks: [TimeInterval] = []
    /// For a second after a Mark the menu bar shows a star instead of the red dot.
    private(set) var isShowingMark = false
    /// The Screenshots of the Meeting in progress.
    private(set) var screenshotCount = 0
    /// For a second after a Screenshot the menu bar shows a camera instead of the red dot.
    private(set) var isShowingScreenshot = false
    /// A Screenshot was not taken for lack of the Screen Recording permission.
    private(set) var screenshotNotAllowed = false
    /// The transcription model while it is downloading or loading, as the menu shows it.
    private(set) var modelMenuTitle: String?
    /// The latest phase, also while a menu is open (the observed title waits for it to close).
    @ObservationIgnored private var modelPhase = ModelMenuPhase.notLoaded
    @ObservationIgnored private var latestModelMenuTitle: String?
    /// The transcription model is in memory, ready for the next Meeting (the welcome window shows it).
    private(set) var isModelReady = false
    private(set) var microphoneDenied = false
    private(set) var recordingError: String?
    private(set) var lastRecordingDirectory: URL?
    /// The audio file being imported, as the menu shows it; `nil` when none.
    private(set) var importingFileName: String?
    private(set) var importingFileIndex = 0
    private(set) var importingFileTotal = 0
    /// The Speaker naming window's draft, if it is open.
    var speakerNaming: SpeakerNamingDraft?
    /// Tracks of the Meeting in progress already notified as silent since the start.
    @ObservationIgnored private var silentTracksNotified: Set<Track> = []
    /// Template for the Meeting in progress or the next one; it can change until the stop.
    var templateName = AppSettings.defaultTemplate {
        didSet {
            if let currentTakkuID { processor.templateChanged(takkuID: currentTakkuID, to: templateName) }
        }
    }

    init() {
        transcriber = LocalTranscriber(models: models)
        AppSettings.registerDefaults()
        models.keepPreviousDefault()
        AppSettings.addReadyMadeProfilesIfNeeded()
        #if DEBUG
        let hasTestIsolation = !Self.isAutomatedTest || Self.hasAutomatedTestIsolation
        #else
        let hasTestIsolation = true
        #endif
        if hasTestIsolation {
            try? TakkuFolder.ensureDefaultTemplate()
        }
        processor = MeetingProcessor(transcriber: transcriber, diarizer: diarizer)
        templateName = AppSettings.defaultTemplate
        Notifications.shared.configure()
        hotKey = GlobalHotKey(id: 1, keyCode: kVK_ANSI_R) { [weak self] in self?.toggle() }
        markHotKey = GlobalHotKey(id: 2, keyCode: kVK_ANSI_M) { [weak self] in self?.mark() }
        screenshotHotKey = GlobalHotKey(id: 3, keyCode: kVK_ANSI_S) { [weak self] in self?.takeScreenshot() }
        Notifications.shared.onAction = { [weak self] action in
            guard let self else { return }
            // A button on an old notification does nothing when its action no longer makes sense.
            switch action {
            case .startMeeting: if !self.isInProgress { Task { await self.start() } }
            case .stopMeeting: if self.isInProgress { self.stop() }
            }
        }
        callDetector.start { [weak self] in
            self?.isInProgress ?? false
        } suggest: { suggestion in
            switch suggestion {
            case .start(let app):
                Notifications.shared.notify(
                    title: String(localized: "Looks like a call in \(app)"), body: String(localized: "Start recording?"),
                    note: nil, action: .startMeeting
                )
            case .stop:
                Notifications.shared.notify(
                    title: String(localized: "The call seems over"), body: String(localized: "Stop recording?"),
                    note: nil, action: .stopMeeting
                )
            }
        }
        if hasTestIsolation {
            processor.resumeAfterLaunch()
        }
        startDailyCleanUp()
        updates.start()
        keepTimerLiveWithoutRebuildingMenus()
        Task { [transcriber] in
            await transcriber.setPhaseHandler { [weak self] phase in
                Task { @MainActor in self?.modelPhaseChanged(phase) }
            }
        }
        // Downloads started from Settings show in the menu too, only for the model in use.
        models.onProgress = { [weak self] model, percent in
            guard let self, model == .selected else { return }
            if let percent {
                modelPhaseChanged(.downloading(percent: percent))
            } else if case .downloading = modelPhase {
                // Downloaded from Settings: nothing loads it until the next Meeting.
                modelPhaseChanged(ModelMenuPhase.notLoaded)
            }
        }
    }

    var isInProgress: Bool { startedAt != nil }

    /// The error to show in the menu: the recording's or the last Processing's.
    var lastError: String? { recordingError ?? processor.lastError }

    /// Menu item with the timer of the Meeting in progress, `nil` if there is none.
    var recordingMenuTitle: String? { recordingMenuTitle(at: now) }

    private func recordingMenuTitle(at date: Date) -> String? {
        guard let startedAt else { return nil }
        return Self.recordingMenuTitle(elapsedLabel(max(0, date.timeIntervalSince(startedAt))))
    }

    private static func recordingMenuTitle(_ elapsed: String) -> String {
        String(localized: "Recording · \(elapsed)")
    }

    /// Menu lines for the Tracks of the Meeting in progress that have had no sound for 2 minutes or more.
    var silenceWarnings: [String] {
        guard let startedAt else { return [] }
        let elapsed = now.timeIntervalSince(startedAt)
        let lastSound = recorder.lastSoundTimes()
        return Track.allCases.compactMap { track in
            guard let trackLastSound = lastSound[track],
                  let minutes = TrackSilence.silentMinutes(lastSound: trackLastSound, now: elapsed)
            else { return nil }
            return switch track {
            case .me: String(localized: "⚠️ No sound from the microphone for \(minutes) min")
            case .others: String(localized: "⚠️ No sound from the system audio for \(minutes) min")
            }
        }
    }

    /// Once per Track per Meeting: a Track with no sound since the start means the Meeting would be lost.
    private func notifySilentTracks() {
        guard let startedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        for (track, lastSound) in recorder.lastSoundTimes()
        where !silentTracksNotified.contains(track) && TrackSilence.neverHeard(lastSound: lastSound, now: elapsed) {
            silentTracksNotified.insert(track)
            logger.error("No sound from the \(track.rawValue, privacy: .public) Track since the start")
            switch track {
            case .me:
                Notifications.shared.notify(
                    title: String(localized: "No sound from the microphone"),
                    body: String(localized: "Takku has recorded nothing from your microphone for 2 minutes. Check System Settings → Privacy & Security → Microphone."),
                    note: nil
                )
            case .others:
                Notifications.shared.notify(
                    title: String(localized: "No sound from the system audio"),
                    body: String(localized: "Takku has recorded nothing from the call for 2 minutes. Check System Settings → Privacy & Security → Screen & System Audio Recording."),
                    note: nil
                )
            }
        }
    }

    /// ⌃⌥⌘M or the menu: marks the current moment of the Meeting in progress as important. Saved at
    /// once, so a crash does not lose it; it stars the Transcript paragraph it falls in.
    func mark() {
        guard let startedAt else { return }
        saveMark(at: Date().timeIntervalSince(startedAt))
        // No sound: the system audio capture would record it in the Others Track.
        flash(\.isShowingMark)
    }

    private func saveMark(at time: TimeInterval) {
        guard let currentDirectory else { return }
        marks.append(time)
        do {
            try Marks.save(marks, inFolder: currentDirectory)
        } catch {
            logger.error("Mark not saved: \(error, privacy: .public)")
            recordingError = error.localizedDescription
        }
    }

    /// Shows `indicator` in the menu bar for a second, in place of the red dot.
    private func flash(_ indicator: ReferenceWritableKeyPath<MeetingController, Bool>) {
        self[keyPath: indicator] = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?[keyPath: indicator] = false
        }
    }

    /// ⌃⌥⌘S or the menu: a Screenshot of the Meeting in progress, saved at once in the Recording
    /// folder, and a Mark at the same moment, made even when the Screenshot is not.
    func takeScreenshot() {
        guard let takkuID = currentTakkuID, let startedAt, let currentDirectory else { return }
        let time = Date().timeIntervalSince(startedAt)
        // A Screenshot is also a Mark, whether the asynchronous capture succeeds or not. Saving it
        // now keeps it even if Stop or a new Meeting changes the in-memory state meanwhile.
        saveMark(at: time)
        guard ScreenshotTaker.isAllowed() else {
            screenshotNotAllowed = true
            flash(\.isShowingMark)
            return
        }
        let capture = Task {
            do {
                // Before the indicator changes: the menu bar is in the image.
                let jpeg = try await ScreenshotTaker.jpeg()
                let folder = currentDirectory.appending(path: Screenshot.folderName, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let taken = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                let name = VaultNaming.available(
                    Screenshot.baseName(startedAt: startedAt, time: time),
                    taken: Set(taken.map { $0.deletingPathExtension().lastPathComponent })
                )
                try jpeg.write(to: folder.appending(path: "\(name).\(Screenshot.fileExtension)"), options: .atomic)
                if self.currentTakkuID == takkuID {
                    screenshotCount += 1
                    screenshotNotAllowed = false
                    flash(\.isShowingScreenshot)
                }
            } catch {
                logger.error("Screenshot not taken: \(error, privacy: .public)")
                if self.currentTakkuID == takkuID {
                    recordingError = String(localized: "Screenshot not taken: \(error.localizedDescription)")
                    flash(\.isShowingMark)
                }
            }
        }
        pendingScreenshots[takkuID, default: []].append(capture)
    }

    /// ⌃⌥⌘R: starts or stops the Meeting from any app.
    func toggle() {
        if isInProgress {
            stop()
        } else {
            Task { await start() }
        }
    }

    func start() async {
        // The menu stays clickable while the permission prompt is open.
        guard !isInProgress, !isRequestingPermission else { return }
        isRequestingPermission = true
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        isRequestingPermission = false

        microphoneDenied = !granted
        guard granted else { return }

        now = Date()
        let model = TranscriptionModel.selected
        let transcription = MeetingTranscription(
            transcriber: transcriber, diarizer: diarizer, model: model, languages: AppSettings.meetingLanguages
        )
        let started: MeetingRecorder.Started
        do {
            started = try recorder.start(at: now) { segment, directory in
                Task { await transcription.segmentClosed(segment, in: directory) }
            }
        } catch {
            logger.error("Starting the recording failed: \(error, privacy: .public)")
            recordingError = error.localizedDescription
            return
        }
        startedAt = now
        recordingError = nil
        silentTracksNotified = []
        currentTakkuID = started.meetingID
        currentDirectory = started.directory
        marks = []
        screenshotCount = 0
        screenshotNotAllowed = false
        currentNoteURL = createMeetingNote(takkuID: started.meetingID, startedAt: now)
        processor.meetingStarted(
            takkuID: started.meetingID,
            startedAt: now,
            templateName: templateName,
            summaryProfile: AppSettings.activeProviderProfile,
            noteURL: currentNoteURL,
            transcription: transcription
        )
        startTicker()

        // On first use this downloads the model: better while the Meeting is in progress.
        Task { [transcriber] in
            do {
                try await transcriber.prepare(model)
            } catch {
                logger.error("Preparing the model failed: \(error, privacy: .public)")
            }
        }
    }

    func stop() {
        guard isInProgress else {
            assertionFailure("Stop without a Meeting in progress")
            return
        }
        startedAt = nil
        ticker?.cancel()
        ticker = nil

        do {
            let stopped = try recorder.stop(at: Date())
            lastRecordingDirectory = stopped.directory
            if !stopped.errors.isEmpty {
                recordingError = String(localized: "Incomplete recording: \(stopped.errors.joined(separator: "; "))")
                logger.error("\(self.recordingError!, privacy: .public)")
            }
        } catch {
            logger.error("Closing the recording failed: \(error, privacy: .public)")
            recordingError = error.localizedDescription
        }
        let captures = currentTakkuID.flatMap { pendingScreenshots.removeValue(forKey: $0) } ?? []
        if let currentTakkuID {
            if captures.isEmpty {
                processor.meetingStopped(takkuID: currentTakkuID)
            } else {
                Task {
                    for capture in captures { await capture.value }
                    processor.meetingStopped(takkuID: currentTakkuID)
                }
            }
        }
        currentTakkuID = nil
        currentDirectory = nil
        currentNoteURL = nil
        calendarEvents = []
        calendarEvent = nil
        marks = []
        screenshotCount = 0
        templateName = AppSettings.defaultTemplate
    }

    /// Opens the naming window only when both the Meeting note and a Transcript with Speakers exist.
    func prepareSpeakerNaming(for meeting: MeetingProcessor.RecentMeeting) -> Bool {
        guard let context = processor.speakerNamingContext(meeting.id) else { return false }
        speakerNaming = SpeakerNamingDraft(
            takkuID: meeting.id, meetingTitle: meeting.title, speakers: context.speakers,
            names: context.names, participants: context.participants
        )
        return true
    }

    /// Confirms the only Retry that can replace edits made to the Transcript in the Vault. By
    /// default the transcription already saved is reused where still valid; the checkbox redoes it all.
    func confirmReprocessing(_ takkuID: UUID) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Reprocess Recording?")
        alert.informativeText = String(localized: "Takku will rebuild the Transcript from the audio, with the current Vocabulary and Speaker names, reusing the transcription already saved where it is still valid. If Processing succeeds, edits you made to the current Transcript will be replaced.")
        let fromScratch = NSButton(checkboxWithTitle: String(localized: "Transcribe again from scratch (slower: also tells the voices apart again)"), target: nil, action: nil)
        fromScratch.state = .off
        alert.accessoryView = fromScratch
        alert.addButton(withTitle: String(localized: "Reprocess Recording"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApplication.shared.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        processor.retry(
            takkuID, templateName: templateName, profile: AppSettings.activeProviderProfile,
            mode: .recording(fromScratch: fromScratch.state == .on)
        )
    }

    /// Creates the Meeting note in the Vault and opens it in the Editor. If that fails the Meeting
    /// goes on anyway: the note will be created at the end of Processing.
    private func createMeetingNote(takkuID: UUID, startedAt: Date) -> URL? {
        guard let vault = Vault.configured else { return nil }
        do {
            // Read after the recording has started: the calendar never delays it.
            let events = MeetingCalendar.eventsInProgress(at: startedAt)
            let url = try vault.createMeetingNote(takkuID: takkuID, startedAt: startedAt, event: events.first)
            // Only with a note: without one there is nothing to point at another event.
            calendarEvents = events
            calendarEvent = events.first
            if AppSettings.opensNotes {
                Vault.openNewFileInEditor(url)
            }
            return url
        } catch {
            logger.error("Meeting note not created: \(error, privacy: .public)")
            recordingError = String(localized: "\(error.localizedDescription) The note will be created at the end of Processing.")
            return nil
        }
    }

    /// From the menu: audio or video files recorded elsewhere (a voice memo, a lecture, a call
    /// recorded by another app), each made a Meeting and processed like a recorded one, with the Template and
    /// Summary Profile chosen now.
    func chooseAudioToImport() {
        // Takku has no Dock icon: without activating it the panel would stay behind the others.
        NSApplication.shared.activate()
        let panel = NSOpenPanel()
        // Video too (mp4, mov): only its audio is read.
        panel.allowedContentTypes = [.audiovisualContent]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose the recording of a meeting, a lecture or a voice memo, audio or video.")
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importAudio(urls) }
    }

    private func importAudio(_ urls: [URL]) async {
        for (index, url) in urls.enumerated() {
            importingFileName = url.lastPathComponent
            importingFileIndex = index + 1
            importingFileTotal = urls.count
            do {
                let imported = try await AudioFileImport.run(
                    url, into: MeetingRecorder.recordingsDirectory, segmentDuration: MeetingRecorder.segmentDuration
                )
                let recording = imported.recording
                logger.notice("Imported \(recording.segments.count) Segments as Meeting \(recording.meetingID, privacy: .public)")
                lastRecordingDirectory = imported.directory
                processor.meetingImported(
                    takkuID: recording.meetingID, startedAt: recording.startedAt, templateName: templateName,
                    summaryProfile: AppSettings.activeProviderProfile, noteURL: createImportedNote(imported),
                    warnings: imported.warnings
                )
            } catch {
                logger.error("Import failed: \(error, privacy: .public)")
                recordingError = String(localized: "Not imported: \(error.localizedDescription)")
            }
        }
        importingFileName = nil
        importingFileIndex = 0
        importingFileTotal = 0
    }

    /// The Meeting note of an imported file, not opened: the notification at the end of Processing
    /// opens it. If it cannot be created here, Processing creates it at the end.
    private func createImportedNote(_ imported: AudioFileImport.Imported) -> URL? {
        guard let vault = Vault.configured else { return nil }
        let startedAt = imported.recording.startedAt
        // Only a date from the file's metadata says when it was recorded: the date of a copied or
        // downloaded file would name the note after an unrelated event.
        let event = imported.isRecordingDate ? MeetingCalendar.eventsInProgress(at: startedAt).first : nil
        do {
            return try vault.createMeetingNote(takkuID: imported.recording.meetingID, startedAt: startedAt, event: event, isImport: true)
        } catch {
            logger.error("Meeting note of the imported file not created: \(error, privacy: .public)")
            return nil
        }
    }

    /// From the menu: the Meeting in progress is for another calendar event, or for none. The note
    /// takes its name (see `Vault.renameForEvent`) and, a moment later, its participants; Obsidian
    /// is shown the renamed note if it was showing it.
    func chooseCalendarEvent(_ event: CalendarEvent?) {
        guard event != calendarEvent, let currentTakkuID, let startedAt, let vault = Vault.configured else { return }
        do {
            guard let noteURL = try vault.findMeetingNote(takkuID: currentTakkuID, expected: currentNoteURL) else { return }
            // Read before the rename: afterwards Obsidian may already show another note.
            let wasShownInObsidian = vault.isShownInObsidian(noteURL) ?? true
            let url = try vault.renameForEvent(noteURL, startedAt: startedAt, from: calendarEvent, to: event)
            calendarEvent = event
            currentNoteURL = url
            processor.noteMoved(takkuID: currentTakkuID, to: url)
            if url != noteURL, wasShownInObsidian, AppSettings.opensNotes {
                RenamedNoteFollower.follow(url, in: vault)
            }
            // Always after the same wait, renamed or not: two choices in a row write in their order.
            Task { [weak self] in
                try? await Task.sleep(for: Vault.settleAfterRename)
                do {
                    // Found again: another choice in the meantime may have renamed it once more.
                    guard let note = try vault.findMeetingNote(takkuID: currentTakkuID, expected: url) else { return }
                    try vault.update(note) { $0.replaceParticipants(with: event?.participants ?? []) }
                } catch {
                    logger.error("Writing the event's participants failed: \(error, privacy: .public)")
                    self?.recordingError = error.localizedDescription
                }
            }
        } catch {
            logger.error("Switching the calendar event failed: \(error, privacy: .public)")
            recordingError = error.localizedDescription
        }
    }

    /// Expired audio is deleted at launch and then once a day.
    private func startDailyCleanUp() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
                guard let self else { return }
                self.processor.cleanUpExpiredRecordings()
            }
        }
    }

    #if DEBUG
    /// Tests without touching the menu (the outcome goes to `smoke-test.txt` next to the data
    /// folder, because `log show` is not always readable):
    /// - `open Takku.app --args -smokeTestSeconds 20` records for N seconds (with
    ///   `-simulateMicrophoneChangeAfter 5` the microphone restarts after 5 seconds, 2 of them silent);
    /// - `open Takku.app --args -transcribeRecording <folder>` reprocesses a Recording of the data folder;
    /// - `open Takku.app --args -importAudio <file>` imports an audio file as a Meeting and processes it;
    /// - `open Takku.app --args -regenerateMeeting <takku_id> -regenerateTemplate <name>` retries a Meeting
    ///   (only the Summary if its audio is deleted) with that Template (a failed one keeps its own)
    ///   and the active Profile;
    /// - always together with `-vaultPath <folder>`, `-testSummaryBaseURL <url>`, `-dataDirectory <folder>`
    ///   and `-testTakkuFolder <folder>`, otherwise the test refuses to start; `-opensNotes NO` does not open
    ///   the Editor.
    private static var isAutomatedTest: Bool {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        return ["smokeTestSeconds", "transcribeRecording", "regenerateMeeting", "importAudio"]
            .contains { arguments[$0] != nil }
    }

    private static var hasAutomatedTestIsolation: Bool {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard ["vaultPath", "testSummaryBaseURL", "dataDirectory", "testTakkuFolder"]
            .allSatisfy({ arguments[$0] != nil }),
            let dataPath = arguments["dataDirectory"] as? String,
            let takkuPath = arguments["testTakkuFolder"] as? String
        else { return false }
        // The runner keeps Recordings and .takku side by side in the run's sandbox. Do not allow
        // an explicit argument to point the test back at the real ~/.takku or another folder.
        let normalized: (String) -> [String] = {
            URL(filePath: $0, directoryHint: .isDirectory).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        }
        let sandbox = normalized(URL(filePath: dataPath, directoryHint: .isDirectory)
            .deletingLastPathComponent().path(percentEncoded: false))
        let takkuFolder = normalized(takkuPath)
        return takkuFolder.starts(with: sandbox)
            && takkuFolder != sandbox
            && takkuFolder != normalized(URL.homeDirectory.appending(path: ".takku").path(percentEncoded: false))
    }

    func runSmokeTestIfRequested() async {
        guard !Self.isAutomatedTest || Self.hasAutomatedTestIsolation else {
            // An automated test without isolation would write to the real Vault with the real Provider.
            recordingError = "Automated test refused: -vaultPath, -testSummaryBaseURL, -dataDirectory and -testTakkuFolder are required."
            writeSmokeTestOutcome(nil)
            return
        }
        if let id = UserDefaults.standard.string(forKey: "regenerateMeeting").flatMap(UUID.init(uuidString:)) {
            processor.retry(
                id, templateName: UserDefaults.standard.string(forKey: "regenerateTemplate") ?? templateName,
                profile: AppSettings.activeProviderProfile
            )
            await processor.waitUntilIdle()
            writeSmokeTestOutcome(processor.lastNoteURL)
            return
        }
        if let path = UserDefaults.standard.string(forKey: "transcribeRecording") {
            let url = await processor.reprocess(URL(filePath: path, directoryHint: .isDirectory))
            writeSmokeTestOutcome(url)
            return
        }
        if let path = UserDefaults.standard.string(forKey: "importAudio") {
            await importAudio([URL(filePath: path)])
            await processor.waitUntilIdle()
            writeSmokeTestOutcome(processor.lastNoteURL ?? processor.lastTranscriptURL)
            return
        }

        let seconds = UserDefaults.standard.integer(forKey: "smokeTestSeconds")
        guard seconds > 0 else { return }
        await start()
        if isInProgress {
            let changeAfter = UserDefaults.standard.integer(forKey: "simulateMicrophoneChangeAfter")
            if changeAfter > 0, changeAfter < seconds {
                try? await Task.sleep(for: .seconds(changeAfter))
                recorder.simulateMicrophoneChange()
                try? await Task.sleep(for: .seconds(seconds - changeAfter))
            } else {
                try? await Task.sleep(for: .seconds(seconds))
            }
            stop()
        }
        writeSmokeTestOutcome(lastRecordingDirectory)
    }

    private func writeSmokeTestOutcome(_ url: URL?) {
        let outcome = lastError.map { "error: \($0)" } ?? "ok: \(url?.path ?? "-")"
        try? outcome.write(
            to: MeetingRecorder.recordingsDirectory.deletingLastPathComponent().appending(path: "smoke-test.txt"),
            atomically: true, encoding: .utf8
        )
    }
    #endif

    /// From the welcome window: downloads and prepares the model before the first Meeting, which
    /// would otherwise wait for it. The menu shows the progress as during a Meeting.
    func prepareTranscriptionModel() async throws {
        try await transcriber.prepare(.selected)
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    private func keepTimerLiveWithoutRebuildingMenus() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] note in
            // Delivered on the main queue, where the menu lives.
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.openMenus == 0 {
                    self.openMenu = menu
                    // Notes deleted or renamed in the Vault since the last time.
                    self.processor.refreshRecent()
                }
                self.openMenus += 1
            }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.openMenus = max(0, self.openMenus - 1)
                if self.openMenus == 0 { self.openMenu = nil }
                self.now = Date()
                if self.modelMenuTitle != self.latestModelMenuTitle { self.modelMenuTitle = self.latestModelMenuTitle }
            }
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.openMenus == 0 {
                    self.now = Date()
                } else {
                    self.updateOpenMenuTimer()
                }
                self.notifySilentTracks()
            }
        }
    }

    /// Like the timer, the model's progress changes the open menu's item in place: rebuilding the
    /// menu at every percent would make it blink. An item appearing or disappearing waits for the
    /// menu to close.
    private func modelPhaseChanged(_ phase: LocalTranscriber.ModelPhase) {
        switch phase {
        case .notLoaded: modelPhaseChanged(ModelMenuPhase.notLoaded)
        case .loading(_, let firstTime): modelPhaseChanged(.loading(firstTime: firstTime))
        case .ready: modelPhaseChanged(ModelMenuPhase.ready)
        }
    }

    private func modelPhaseChanged(_ phase: ModelMenuPhase) {
        // Progress reports can arrive after the download is over.
        if case .downloading = phase {
            switch modelPhase {
            case .loading, .ready: return
            case .notLoaded, .downloading: break
            }
        }
        modelPhase = phase
        // Only on a change: every write of observed state rebuilds an open menu.
        let isReady = if case .ready = phase { true } else { false }
        if isReady != isModelReady { isModelReady = isReady }
        let title = Self.modelMenuTitle(phase)
        // Whole percents only: the download reports progress many times a second.
        guard title != latestModelMenuTitle else { return }
        logger.info("Transcription model: \(title ?? "ready or not loaded", privacy: .public)")
        if openMenus == 0 {
            modelMenuTitle = title
        } else if let shown = latestModelMenuTitle, let title {
            openMenu?.items.first { $0.title == shown }?.title = title
        }
        latestModelMenuTitle = title
    }

    private static func modelMenuTitle(_ phase: ModelMenuPhase) -> String? {
        switch phase {
        case .notLoaded, .ready:
            nil
        case .downloading(let percent) where percent < 100:
            String(localized: "Downloading transcription model… \(percent)%")
        case .downloading, .loading(firstTime: true):
            String(localized: "Preparing transcription model, first time only: a few minutes…")
        case .loading(firstTime: false):
            String(localized: "Loading transcription model…")
        }
    }

    /// Another open menu (e.g. a picker in Settings) has no timer item: nothing changes.
    private func updateOpenMenuTimer() {
        guard let title = recordingMenuTitle(at: Date()) else { return }
        let prefix = Self.recordingMenuTitle("")
        openMenu?.items.first { $0.title.hasPrefix(prefix) }?.title = title
    }
}

/// What the menu says about the transcription model.
private enum ModelMenuPhase {
    case notLoaded
    case downloading(percent: Int)
    case loading(firstTime: Bool)
    case ready
}
