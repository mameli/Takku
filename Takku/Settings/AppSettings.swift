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
    private static let openInObsidianKey = "openInObsidian"
    /// Also used by `@AppStorage` in the menu: it must follow Profiles added or deleted in Settings.
    static let summaryProfilesKey = "summaryProfiles"
    private static let defaultTemplateKey = "defaultTemplate"
    private static let retentionDaysKey = "retentionDays"
    /// Also used by `@AppStorage` in the menu and in Settings, so the two stay in sync.
    static let transcriptionModelKey = "transcriptionModel"
    /// Also used by `@AppStorage` in the menu and in Settings, so the two stay in sync.
    static let activeProviderProfileKey = "activeProviderProfile"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            openInObsidianKey: true,
            suggestCallsKey: false,
            checkForUpdatesKey: true,
            defaultTemplateKey: Template.defaultName,
            retentionDaysKey: Retention.days,
        ])
    }

    static var vaultPath: String? {
        get { UserDefaults.standard.string(forKey: vaultPathKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: vaultPathKey) }
    }

    /// The WhisperKit variant used for new Meetings and Retry; see `TranscriptionModel.selected`.
    static var transcriptionModelID: String? {
        UserDefaults.standard.string(forKey: transcriptionModelKey)
    }

    /// Days the audio is kept.
    static var retentionDays: Int {
        get { max(1, UserDefaults.standard.integer(forKey: retentionDaysKey)) }
        set { UserDefaults.standard.set(max(1, newValue), forKey: retentionDaysKey) }
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
    /// those of v1's `language` setting.
    static var meetingLanguages: [String] {
        get {
            UserDefaults.standard.stringArray(forKey: meetingLanguagesKey).map(MeetingLanguages.normalized)
                ?? MeetingLanguages.migrated(fromLanguageSetting: UserDefaults.standard.string(forKey: languageKey))
        }
        set { UserDefaults.standard.set(MeetingLanguages.normalized(newValue), forKey: meetingLanguagesKey) }
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

    /// Off only in automated tests, which write to a test Vault Obsidian does not know.
    static var openInObsidian: Bool {
        UserDefaults.standard.bool(forKey: openInObsidianKey)
    }

    static var summaryProfiles: [ProviderProfile] {
        get {
            decodeProfiles(UserDefaults.standard.data(forKey: summaryProfilesKey))
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: summaryProfilesKey) }
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

    /// Name (without `.md`) of the Template proposed when every Meeting starts.
    static var defaultTemplate: String {
        get { UserDefaults.standard.string(forKey: defaultTemplateKey) ?? Template.defaultName }
        set { UserDefaults.standard.set(newValue, forKey: defaultTemplateKey) }
    }
}
