import Foundation
import TakkuCore

/// Takku's settings, editable in the Settings window.
enum AppSettings {
    /// Also used by `@AppStorage` in the menu and in the welcome window.
    static let vaultPathKey = "vaultPath"
    /// v1's single language (`it`, `en`, `auto`), read only to migrate it to `meetingLanguagesKey`.
    private static let languageKey = "language"
    private static let meetingLanguagesKey = "meetingLanguages"
    /// Also used by `@AppStorage` in Settings.
    static let useCalendarKey = "useCalendar"
    /// Also used by `@AppStorage` in Settings.
    static let suggestCallsKey = "suggestCalls"
    /// Also used by `@AppStorage` in Settings.
    static let checkForUpdatesKey = "checkForUpdates"
    private static let opensNotesKey = "opensNotes"
    /// Also used by `@AppStorage` in Settings.
    static let opensNoteAtStartKey = "opensNoteAtStart"
    /// Bundle ID of the Editor chosen in Settings, empty if never chosen. Also used by `@AppStorage`
    /// in Settings and in the menu.
    static let editorKey = "editor"
    /// Also used by `@AppStorage` in the menu: it must follow Profiles added or deleted in Settings.
    static let summaryProfilesKey = "summaryProfiles"
    private static let readyMadeProfilesAddedKey = "readyMadeProfilesAdded"
    private static let defaultTemplateKey = "defaultTemplate"
    private static let retentionDaysKey = "retentionDays"
    /// Also used by `@AppStorage` in Settings.
    static let keepSummaryLogKey = "keepSummaryLog"
    /// Also used by `@AppStorage` in the menu and in Settings, so the two stay in sync.
    static let transcriptionModelKey = "transcriptionModel"
    /// Also used by `@AppStorage` in the menu and in Settings, so the two stay in sync.
    static let activeProviderProfileKey = "activeProviderProfile"
    /// Also used by `@AppStorage` in Settings.
    static let recognizeVoicesKey = "recognizeVoices"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            opensNotesKey: true,
            suggestCallsKey: false,
            checkForUpdatesKey: true,
            defaultTemplateKey: Template.defaultName,
            retentionDaysKey: Retention.days,
            keepSummaryLogKey: true,
        ])
    }

    static var vaultPath: String? {
        get { UserDefaults.standard.string(forKey: vaultPathKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: vaultPathKey) }
    }

    /// The transcription model used for new Meetings and Retry; see `TranscriptionModel.selected`.
    static var transcriptionModelID: String? {
        get { UserDefaults.standard.string(forKey: transcriptionModelKey) }
        set { UserDefaults.standard.set(newValue, forKey: transcriptionModelKey) }
    }

    /// Days the audio is kept; `nil` forever, saved as 0 (which no earlier version could save).
    static var retentionDays: Int? {
        get {
            let days = UserDefaults.standard.integer(forKey: retentionDaysKey)
            return days == 0 ? nil : days
        }
        set { UserDefaults.standard.set(newValue.map { max(1, $0) } ?? 0, forKey: retentionDaysKey) }
    }

    /// Copy every Summary's requests and replies to the Summary log.
    static var keepSummaryLog: Bool {
        UserDefaults.standard.bool(forKey: keepSummaryLogKey)
    }

    /// Remember the voices of named Speakers to suggest their names in later Meetings (ADR 0006).
    /// Off unless the user turns it on: voices are biometric data.
    static var recognizeVoices: Bool {
        UserDefaults.standard.bool(forKey: recognizeVoicesKey)
    }

    #if DEBUG
    /// In automated tests every Summary goes to the fake server, even for Meetings saved with another
    /// Profile; `-testSummaryBaseURL none` tests the "Transcript" choice; `-testSummaryMaxContextTokens 8192`
    /// forces a Summary in blocks. `nil` outside tests.
    static var testSummaryProfile: ProviderProfile?? {
        let maxContextTokens = UserDefaults.standard.integer(forKey: "testSummaryMaxContextTokens")
        return UserDefaults.standard.string(forKey: "testSummaryBaseURL").map {
            $0 == "none" ? nil : ProviderProfile(
                name: "Test server", baseURL: $0, model: "test",
                maxContextTokens: maxContextTokens > 0 ? maxContextTokens : ProviderProfile.defaultMaxContextTokens
            )
        }
    }
    #endif

    /// The languages a Meeting can be in (see `MeetingLanguages`); until the user changes them,
    /// those saved by `saveMeetingLanguagesIfNeeded`.
    static var meetingLanguages: [String] {
        get {
            UserDefaults.standard.stringArray(forKey: meetingLanguagesKey).map(MeetingLanguages.normalized)
                ?? MeetingLanguages.defaults(macLanguages: Locale.preferredLanguages)
        }
        set { UserDefaults.standard.set(MeetingLanguages.normalized(newValue), forKey: meetingLanguagesKey) }
    }

    /// At launch, on a Mac that never chose the Meeting languages, saves them: the Mac's languages
    /// and English; a Takku already set up keeps Italian and English, or v1's `language`, with
    /// the Mac's languages added. Saved, they do not change behind the user's back with the Mac's.
    static func saveMeetingLanguagesIfNeeded() {
        guard UserDefaults.standard.stringArray(forKey: meetingLanguagesKey) == nil else { return }
        let mac = Locale.preferredLanguages
        meetingLanguages = vaultPath == nil
            ? MeetingLanguages.defaults(macLanguages: mac)
            : MeetingLanguages.migrated(fromLanguageSetting: UserDefaults.standard.string(forKey: languageKey), macLanguages: mac)
    }

    /// Name the Meeting note after the calendar event in progress and list its participants.
    static var useCalendar: Bool {
        UserDefaults.standard.bool(forKey: useCalendarKey)
    }

    /// Suggest starting a Meeting when a call starts, and stopping it when it ends.
    static var suggestCalls: Bool {
        UserDefaults.standard.bool(forKey: suggestCallsKey)
    }

    /// Ask GitHub once a day whether a newer Takku is out.
    static var checkForUpdates: Bool {
        UserDefaults.standard.bool(forKey: checkForUpdatesKey)
    }

    /// Off only in automated tests, which write to a test Vault no Editor should open.
    static var opensNotes: Bool {
        UserDefaults.standard.bool(forKey: opensNotesKey)
    }

    /// Open the Meeting note in the Editor as soon as the Meeting starts. Off by default: the note
    /// is opened from the menu (*Open note*) when wanted.
    static var opensNoteAtStart: Bool {
        UserDefaults.standard.bool(forKey: opensNoteAtStartKey)
    }

    /// See `Editor.current` for the Editor actually in use.
    static var chosenEditor: String? {
        UserDefaults.standard.string(forKey: editorKey)
    }

    static var summaryProfiles: [ProviderProfile] {
        get {
            decodeProfiles(UserDefaults.standard.data(forKey: summaryProfilesKey))
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: summaryProfilesKey) }
    }

    /// Once, at the first launch without Profiles: the ready-made ones, none active (Ollama may not
    /// be running, and the others have no key yet). Deleted, they do not come back.
    static func addReadyMadeProfilesIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: readyMadeProfilesAddedKey) else { return }
        UserDefaults.standard.set(true, forKey: readyMadeProfilesAddedKey)
        if summaryProfiles.isEmpty { summaryProfiles = ProviderProfile.readyMade() }
    }

    static func decodeProfiles(_ data: Data?) -> [ProviderProfile] {
        data.flatMap { try? JSONDecoder().decode([ProviderProfile].self, from: $0) } ?? []
    }

    static var activeProviderProfileID: UUID? {
        get { UserDefaults.standard.string(forKey: activeProviderProfileKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: activeProviderProfileKey) }
    }

    static var activeProviderProfile: ProviderProfile? {
        #if DEBUG
        // Automated tests: `--args -testSummaryBaseURL http://localhost:8765/v1` uses a fake server
        // without touching the user's Profiles.
        if let testSummaryProfile { return testSummaryProfile }
        #endif
        return summaryProfiles.first { $0.id == activeProviderProfileID }
    }

    /// The folders of the notes folder, outside `Meetings/`, where imports were written (`takku import
    /// --folder`, a Template's `folder:`): Takku and `takku` look for notes there too.
    static var noteFolders: [String] {
        UserDefaults.standard.stringArray(forKey: noteFoldersKey) ?? []
    }

    static func rememberNoteFolder(_ folder: String) {
        let isMeetings = folder.split(separator: "/").first.map { $0.caseInsensitiveCompare(VaultNaming.meetingsFolder) == .orderedSame } ?? true
        guard !isMeetings, !noteFolders.contains(folder) else { return }
        UserDefaults.standard.set(noteFolders + [folder], forKey: noteFoldersKey)
    }

    private static let noteFoldersKey = "noteFolders"

    /// Name (without `.md`) of the Template proposed when every Meeting starts.
    static var defaultTemplate: String {
        get { UserDefaults.standard.string(forKey: defaultTemplateKey) ?? Template.defaultName }
        set { UserDefaults.standard.set(newValue, forKey: defaultTemplateKey) }
    }
}
